#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
license="$repository_root/LICENSE.md"
cla="$repository_root/CONTRIBUTOR_LICENSE_AGREEMENT.md"
contributing="$repository_root/CONTRIBUTING.md"
pull_request_template="$repository_root/.github/PULL_REQUEST_TEMPLATE.md"
cla_workflow="$repository_root/.github/workflows/cla.yml"
readonly expected_license_sha256=c0ea4a896d2c8c394b29f9427589996db826cd501c512279ff0ed3ef48fabbe5
readonly expected_cla_sha256=16990ce778b15efc0b60a51b54997a0fbb535cc3e4df85d97e3af2e80dc64bca

fail() {
    printf 'contribution licensing contract: FAIL (%s)\n' "$1" >&2
    exit 1
}

[[ -f $license && ! -L $license ]] || fail license
[[ $(shasum -a 256 "$license" | awk '{print $1}') \
    == "$expected_license_sha256" ]] || fail license
[[ -f $cla && ! -L $cla ]] || fail cla
[[ $(shasum -a 256 "$cla" | awk '{print $1}') == "$expected_cla_sha256" ]] \
    || fail cla-version
[[ -f $contributing && ! -L $contributing ]] || fail contributing
[[ -f $pull_request_template && ! -L $pull_request_template ]] \
    || fail pull-request-template
[[ -f $cla_workflow && ! -L $cla_workflow ]] || fail cla-workflow

grep -Fq \
    'the person or legal entity that controls the GitHub account `TREAFREE`' \
    "$cla" || fail cla-owner
grep -Fq \
    'commercial, proprietary, open source, or source-available terms' \
    "$cla" || fail cla-commercial-license
grep -Fq 'You retain ownership of Your Contribution.' "$cla" \
    || fail cla-contributor-ownership
grep -Fq 'worldwide, non-exclusive, perpetual, irrevocable' "$cla" \
    || fail cla-copyright-grant
grep -Fq 'patent license' "$cla" || fail cla-patent-grant
grep -Fq 'does not assign ownership' "$cla" || fail cla-no-assignment
grep -Fq 'affirmatively checking the CLA checkbox' "$cla" \
    || fail cla-acceptance
if grep -Eq \
    'grant the Project Owner and recipients|grant ordinary recipients' "$cla"; then
    fail cla-commercial-rights-scope
fi

grep -Fq -- \
    '- [ ] I have read and agree to the [SpaceTrace Contributor License Agreement](https://github.com/TREAFREE/SpaceTrace/blob/main/CONTRIBUTOR_LICENSE_AGREEMENT.md), version 1.0, SHA-256 `16990ce778b15efc0b60a51b54997a0fbb535cc3e4df85d97e3af2e80dc64bca`' \
    "$pull_request_template" || fail pull-request-checkbox
grep -Fq \
    'PR 不得合并，除非所有贡献者都已明确接受' \
    "$contributing" || fail contributing-merge-gate
grep -Fq 'PolyForm Noncommercial License 1.0.0' "$contributing" \
    || fail contributing-project-license
grep -Fq 'pull_request_target:' "$cla_workflow" || fail cla-workflow-trigger
grep -Fq 'github.event.pull_request.base.sha' "$cla_workflow" \
    || fail cla-workflow-trusted-base
grep -Fq 'persist-credentials: false' "$cla_workflow" \
    || fail cla-workflow-credentials
grep -Fq 'bash Scripts/check-pull-request-cla.sh "$GITHUB_EVENT_PATH"' \
    "$cla_workflow" || fail cla-workflow-checker
if grep -Eq 'pull_request\.head|secrets\.' "$cla_workflow"; then
    fail cla-workflow-untrusted-input
fi

if grep -Eq 'Proposed license: MIT|license remains `NOASSERTION`' \
    "$repository_root/README.md" "$contributing"; then
    fail stale-license-claim
fi

printf 'contribution licensing contract: PASS\n'
