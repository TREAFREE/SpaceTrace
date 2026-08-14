#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

fail() {
    printf 'verification prerequisites contract: RED: %s\n' "$1" >&2
    exit 1
}

missing_output=''
missing_status=0
missing_output=$(cd "$repository_root" && PATH=/usr/bin:/bin /usr/bin/make -s prerequisites 2>&1) || missing_status=$?

[[ $missing_status -ne 0 ]] || fail 'missing ripgrep was accepted'
[[ $missing_output == *'Missing required verification tool: rg'* ]] || fail 'missing ripgrep did not produce the stable diagnostic'

available_output=''
available_status=0
available_output=$(cd "$repository_root" && /usr/bin/make -s prerequisites 2>&1) || available_status=$?

[[ $available_status -eq 0 ]] || fail "available toolchain was rejected: ${available_output}"

printf 'verification prerequisites contract: PASS (2 cases)\n'
