#!/bin/bash

set -euo pipefail

readonly program_name=check-pull-request-cla.sh
readonly maximum_event_bytes=1048576
readonly accepted_pattern='^- \[[xX]\] I have read and agree to the \[SpaceTrace Contributor License Agreement\]\(https://github\.com/TREAFREE/SpaceTrace/blob/main/CONTRIBUTOR_LICENSE_AGREEMENT\.md\), version 1\.0, SHA-256 `16990ce778b15efc0b60a51b54997a0fbb535cc3e4df85d97e3af2e80dc64bca`, and I have authority to submit every Contribution in this PR\.$'

usage() {
    printf 'usage: %s <event.json>\n' "$program_name" >&2
    exit 64
}

event_path=${1:-}
[[ $# -eq 1 && -n $event_path ]] || usage

event_error() {
    printf 'pull-request CLA check: ERROR (event contract)\n' >&2
    exit 2
}

[[ $event_path == /* && -f $event_path && ! -L $event_path ]] || event_error
event_bytes=$(wc -c <"$event_path" | tr -d ' ') || event_error
[[ $event_bytes =~ ^[0-9]+$ && $event_bytes -le $maximum_event_bytes ]] \
    || event_error
command -v jq >/dev/null 2>&1 || event_error
jq -e \
    'type == "object" and (.pull_request | type == "object") and ((.pull_request.body == null) or (.pull_request.body | type == "string"))' \
    "$event_path" >/dev/null 2>&1 || event_error

body=$(jq -r '.pull_request.body // ""' "$event_path" 2>/dev/null) \
    || event_error
if printf '%s\n' "$body" | LC_ALL=C grep -Eq "$accepted_pattern"; then
    printf 'pull-request CLA check: PASS\n'
    exit 0
fi

printf 'pull-request CLA check: FAIL (affirmative acceptance required)\n'
exit 1
