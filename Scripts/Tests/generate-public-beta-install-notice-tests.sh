#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
generator="$repository_root/Scripts/generate-public-beta-install-notice.sh"

if [[ ! -x "$generator" ]]; then
    printf 'RED: public Beta install-notice generator is missing\n' >&2
    exit 1
fi

scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/spacetrace-install-notice-contract.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT

readonly version=0.1.0-beta.1
readonly commit=0123456789abcdef0123456789abcdef01234567

expect_failure() {
    local label=$1
    shift
    if "$@" >"$scratch_root/$label.output" 2>&1; then
        printf 'FAIL: expected rejection for %s\n' "$label" >&2
        exit 1
    fi
}

expect_failure missing-arguments "$generator"
expect_failure invalid-version "$generator" \
    --version not-a-version \
    --commit "$commit" \
    --output "$scratch_root/invalid-version.txt"
expect_failure invalid-commit "$generator" \
    --version "$version" \
    --commit not-a-commit \
    --output "$scratch_root/invalid-commit.txt"

first="$scratch_root/first.txt"
second="$scratch_root/second.txt"
"$generator" --version "$version" --commit "$commit" --output "$first"
"$generator" --version "$version" --commit "$commit" --output "$second"
cmp "$first" "$second"

expect_failure existing-output "$generator" \
    --version "$version" \
    --commit "$commit" \
    --output "$first"

grep -Fxq 'SpaceTrace Public Beta / SpaceTrace 公开测试版' "$first"
grep -Fxq "Version / 版本: $version" "$first"
grep -Fxq "Source commit / 源码提交: $commit" "$first"
grep -Fxq \
    'This build is ad-hoc signed and not notarized. macOS cannot verify its publisher.' \
    "$first"
grep -Fxq \
    '此构建仅采用 ad-hoc 签名且未经过 Apple 公证；macOS 无法验证发布者身份。' \
    "$first"
grep -Fxq "  shasum -a 256 -c \"SpaceTrace-$version.sha256\"" "$first"
grep -Fxq \
    "  plutil -extract sourceCommit raw \"SpaceTrace-$version.manifest.json\"" \
    "$first"
grep -Fq 'System Settings > Privacy & Security > Open Anyway' "$first"
grep -Fq '系统设置 > 隐私与安全性 > 仍要打开' "$first"
grep -Fq 'Do not disable Gatekeeper globally or recursively remove quarantine.' "$first"
grep -Fq '不要全局关闭 Gatekeeper，也不要递归移除 quarantine 属性。' "$first"
grep -Fq 'Manual downloads only; this Beta has no automatic updater.' "$first"
grep -Fq '仅支持手动下载；此 Beta 不包含自动更新器。' "$first"
grep -Fq 'SpaceTrace tracks storage change; it does not clean or delete files.' "$first"
grep -Fq 'SpaceTrace 只跟踪存储变化，不会清理或删除文件。' "$first"
grep -Fq \
    'License: PolyForm Noncommercial 1.0.0; noncommercial use, modification, and sharing are permitted.' \
    "$first"
grep -Fq 'Commercial use is not licensed.' "$first"
grep -Fq \
    '许可证：PolyForm Noncommercial 1.0.0；允许非商业使用、修改与分享，不授予商业使用权。' \
    "$first"
grep -Fxq \
    'https://polyformproject.org/licenses/noncommercial/1.0.0' \
    "$first"

if grep -Eq 'spctl[[:space:]]+--master-disable|xattr[[:space:]]+-[[:alnum:]]*r' "$first"; then
    printf 'FAIL: install notice contains a broad Gatekeeper bypass\n' >&2
    exit 1
fi
local_path_pattern='/''Users/|/private/|/tmp/'
if grep -Eq "$local_path_pattern" "$first"; then
    printf 'FAIL: install notice contains a local filesystem path\n' >&2
    exit 1
fi
[[ $(stat -f '%Lp' "$first") == 644 ]]
[[ $(stat -f '%z' "$first") -le 16384 ]]

printf 'public Beta install-notice contract: PASS\n'
