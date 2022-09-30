#!/usr/bin/env bash
set -Eeuo pipefail

[ -f versions.json ] # run "versions.sh" first

jqt='.jq-template.awk'

generated_warning() {
	cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "apply-templates.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#

	EOH
}

export version=3.9
export variant=ubuntu-jammy-curl
template='Dockerfile-linux.template'

{
	generated_warning
	gawk -f "$jqt" "$template"
} > "huh.Dockerfile"
