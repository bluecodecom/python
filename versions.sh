#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

# https://github.com/docker-library/python/issues/365
minimumSetuptoolsVersion='57.5.0'
# for historical reasons, setuptools gets pinned to either the version bundled with each Python version or this, whichever is higher

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( $(ls -d */ | sort -V) )  # list directories, sorted numerically by version
	json='{}'
else
	json="$(< versions.json)"
fi
versions=( "${versions[@]%/}" )

getPipCommit="$(
	wget -qO- --header 'Accept: application/json' 'https://github.com/pypa/get-pip/commits/main/public/get-pip.py.atom' \
		| jq -r '.payload | first(.commitGroups[].commits[].oid)'
)"
getPipUrl="https://github.com/pypa/get-pip/raw/$getPipCommit/public/get-pip.py"
getPipSha256="$(wget -qO- "$getPipUrl" | sha256sum | cut -d' ' -f1)"
export getPipCommit getPipUrl getPipSha256

has_linux_version() {
	local dir="$1"; shift
	local dirVersion="$1"; shift
	local fullVersion="$1"; shift

	if ! wget -q -O /dev/null -o /dev/null --spider "https://www.python.org/ftp/python/$dirVersion/Python-$fullVersion.tar.xz"; then
		return 1
	fi

	return 0
}

has_windows_version() {
	local dir="$1"; shift
	local dirVersion="$1"; shift
	local fullVersion="$1"; shift

	if ! wget -q -O /dev/null -o /dev/null --spider "https://www.python.org/ftp/python/$dirVersion/python-$fullVersion-amd64.exe"; then
		return 1
	fi

	return 0
}

for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"
	export version rcVersion

	rcGrepV='-v'
	if [ "$rcVersion" != "$version" ]; then
		rcGrepV=
	fi

	possibles=( $(
		{
			git ls-remote --tags https://github.com/python/cpython.git "refs/tags/v${rcVersion}.*" \
				| sed -r 's!^.*refs/tags/v([0-9a-z.]+).*$!\1!' \
				| grep $rcGrepV -E -- '[a-zA-Z]+' \
				|| :

			# this page has a very aggressive varnish cache in front of it, which is why we also scrape tags from GitHub
			wget -qO- 'https://www.python.org/ftp/python/' \
				| grep '<a href="'"$rcVersion." \
				| sed -r 's!.*<a href="([^"/]+)/?".*!\1!' \
				| grep $rcGrepV -E -- '[a-zA-Z]+' \
				|| :
		} | sort -ruV
	) )
	fullVersion=
	hasWindows=
	declare -A impossible=()
	for possible in "${possibles[@]}"; do
		rcPossible="${possible%%[a-z]*}"

		# varnish is great until it isn't (usually the directory listing we scrape below is updated/uncached significantly later than the release being available)
		if has_linux_version "$version" "$rcPossible" "$possible"; then
			fullVersion="$possible"
			if has_windows_version "$version" "$rcPossible" "$possible"; then
				hasWindows=1
			fi
			break
		fi

		if [ -n "${impossible[$rcPossible]:-}" ]; then
			continue
		fi
		impossible[$rcPossible]=1
		possibleVersions=( $(
			wget -qO- -o /dev/null "https://www.python.org/ftp/python/$rcPossible/" \
				| grep '<a href="Python-'"$rcVersion"'.*\.tar\.xz"' \
				| sed -r 's!.*<a href="Python-([^"/]+)\.tar\.xz".*!\1!' \
				| grep $rcGrepV -E -- '[a-zA-Z]+' \
				| sort -rV \
				|| true
		) )
		for possibleVersion in "${possibleVersions[@]}"; do
			if has_linux_version "$version" "$rcPossible" "$possibleVersion"; then
				fullVersion="$possibleVersion"
				if has_windows_version "$version" "$rcPossible" "$possible"; then
					hasWindows=1
				fi
				break
			fi
		done
	done

	if [ -z "$fullVersion" ]; then
		{
			echo
			echo
			echo "  error: cannot find $version (alpha/beta/rc?)"
			echo
			echo
		} >&2
		exit 1
	fi

	ensurepipVersions="$(
		wget -qO- "https://github.com/python/cpython/raw/v$fullVersion/Lib/ensurepip/__init__.py" \
			| grep -E '^[^[:space:]]+_VERSION[[:space:]]*='
	)"
	pipVersion="$(sed -nre 's/^_PIP_VERSION[[:space:]]*=[[:space:]]*"(.*?)".*/\1/p' <<<"$ensurepipVersions")"
	if [ -z "$pipVersion" ]; then
		echo >&2 "error: $version: missing pip version"
		exit 1
	fi
	if ! wget -q -O /dev/null -o /dev/null --spider "https://pypi.org/pypi/pip/$pipVersion/json"; then
		echo >&2 "error: $version: pip version ($pipVersion) seems to be invalid?"
		exit 1
	fi

	setuptoolsVersion="$(sed -nre 's/^_SETUPTOOLS_VERSION[[:space:]]*=[[:space:]]*"(.*?)".*/\1/p' <<<"$ensurepipVersions")"
	case "$rcVersion" in
		3.8 | 3.9 | 3.10 | 3.11)
			if [ -z "$setuptoolsVersion" ]; then
				echo >&2 "error: $version: missing setuptools version"
				exit 1
			fi
			if ! wget -q -O /dev/null -o /dev/null --spider "https://pypi.org/pypi/setuptools/$setuptoolsVersion/json"; then
				echo >&2 "error: $version: setuptools version ($setuptoolsVersion) seems to be invalid?"
				exit 1
			fi

			# TODO remove this once Python 3.8 is either "new enough setuptools" or EOL
			setuptoolsVersion="$(
				{
					echo "$setuptoolsVersion"
					echo "$minimumSetuptoolsVersion"
				} | sort -rV | head -1
			)"

			# https://github.com/docker-library/python/issues/781 (TODO remove this if 3.10 and 3.11 embed a newer setuptools and this section no longer applies)
			if [ "$setuptoolsVersion" = '65.5.0' ]; then
				setuptoolsVersion='65.5.1'
			fi
			;;

		*)
			# https://github.com/python/cpython/issues/95299 -> https://github.com/python/cpython/commit/ece20dba120a1a4745721c49f8d7389d4b1ee2a7
			if [ -n "$setuptoolsVersion" ]; then
				echo >&2 "error: $version: unexpected setuptools: $setuptoolsVersion"
				exit 1
			fi
			;;
	esac

	# TODO wheelVersion, somehow: https://github.com/docker-library/python/issues/365#issuecomment-914669320

	echo "$version: $fullVersion (pip $pipVersion${setuptoolsVersion:+, setuptools $setuptoolsVersion}${hasWindows:+, windows})"

	export fullVersion pipVersion setuptoolsVersion hasWindows
	json="$(jq <<<"$json" -c '
		.[env.version] = {
			version: env.fullVersion,
			pip: {
				version: env.pipVersion,
			},
			"get-pip": {
				version: "https://github.com/pypa/get-pip/commit/\(env.getPipCommit)",
				url: env.getPipUrl,
				sha256: env.getPipSha256,
			},
			variants: [
			  (
			  "jammy-curl"
			  | "ubuntu-" + .
			  ) #,  # need comma for the rest
#				(
#					"bullseye",
#					"buster"
#				| ., "slim-" + .)#, # https://github.com/docker-library/ruby/pull/142#issuecomment-320012893
#				(
#					"3.16",
#					"3.15"
#				| "alpine" + .) #,
#				if env.hasWindows != "" then
#					(
#						"ltsc2022",
#						"1809"
#					| "windows/windowsservercore-" + .)
#				else empty end
			],
		} + if env.setuptoolsVersion != "" then {
			setuptools: {
				version: env.setuptoolsVersion,
			},
		} else {} end
	')"
done

jq <<<"$json" -S . > versions.json
