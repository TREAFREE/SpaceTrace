#!/bin/zsh

set -euo pipefail

program_name=${0:t}

usage() {
    print -u2 "usage: $program_name --version <semver> --commit <git-sha> --output <new-file>"
}

fail() {
    print -u2 "error: $1"
    exit "${2:-2}"
}

version=""
commit=""
output=""

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { usage; exit 64; }
            version=$2
            shift 2
            ;;
        --commit)
            (( $# >= 2 )) || { usage; exit 64; }
            commit=$2
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { usage; exit 64; }
            output=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

[[ -n $version && -n $commit && -n $output ]] || { usage; exit 64; }
print -r -- "$version" | /usr/bin/grep -Eq \
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' \
    || fail "version must be valid Semantic Versioning" 64
print -r -- "$commit" | /usr/bin/grep -Eq '^[0-9a-f]{40}$' \
    || fail "commit must be a 40-character lowercase Git SHA" 64
[[ ! -e $output && ! -L $output ]] || fail "output already exists"

output_parent=${output:h}
output_name=${output:t}
[[ -n $output_name && $output_name != . && $output_name != .. ]] \
    || fail "output must name a new file" 64
[[ -d $output_parent ]] || fail "output parent does not exist"
output_parent=$(cd "$output_parent" && pwd -P)
output_path="$output_parent/$output_name"

temporary_output=$(mktemp "$output_parent/.spacetrace-install-notice.XXXXXX") \
    || fail "could not create private staging output"
cleanup() {
    [[ -z $temporary_output ]] || rm -f -- "$temporary_output"
}
trap cleanup EXIT INT TERM HUP

cat >"$temporary_output" <<NOTICE
SpaceTrace Public Beta / SpaceTrace 公开测试版
Version / 版本: $version
Source commit / 源码提交: $commit

Security notice
---------------
This build is ad-hoc signed and not notarized. macOS cannot verify its publisher.
SpaceTrace tracks storage change; it does not clean or delete files.
License: PolyForm Noncommercial 1.0.0; noncommercial use, modification, and sharing are permitted.
Commercial use is not licensed.
https://polyformproject.org/licenses/noncommercial/1.0.0

Before installation, download the DMG, manifest, SHA-256 file, SPDX document, and
third-party notices from the same GitHub Release. In that download directory run:

  shasum -a 256 -c "SpaceTrace-$version.sha256"
  plutil -extract sourceCommit raw "SpaceTrace-$version.manifest.json"

All four checksum entries must report OK, and sourceCommit must equal the value above.

Installation
------------
1. Open the DMG and drag SpaceTrace.app to Applications.
2. Try to open SpaceTrace normally. The first launch is expected to be blocked.
3. Only if you trust the commit and checksums, open
   System Settings > Privacy & Security > Open Anyway and confirm the one-app exception.
4. Open SpaceTrace again from Applications.

Do not disable Gatekeeper globally or recursively remove quarantine.
Manual downloads only; this Beta has no automatic updater.
A replacement may require directory reselection; rollback is not yet qualified.

安全提示
--------
此构建仅采用 ad-hoc 签名且未经过 Apple 公证；macOS 无法验证发布者身份。
SpaceTrace 只跟踪存储变化，不会清理或删除文件。
许可证：PolyForm Noncommercial 1.0.0；允许非商业使用、修改与分享，不授予商业使用权。

安装前，请从同一个 GitHub Release 下载 DMG、manifest、SHA-256 文件、SPDX 文档和
第三方声明，并在这些下载文件所在的目录执行上面的两条命令。四项 checksum 必须全部
显示 OK，且 sourceCommit 必须与本文顶部的值完全一致。

安装步骤
--------
1. 打开 DMG，把 SpaceTrace.app 拖入“应用程序”文件夹。
2. 正常尝试打开 SpaceTrace；首次启动预期会被 macOS 拦截。
3. 只有在信任源码提交和校验值时，才进入
   系统设置 > 隐私与安全性 > 仍要打开，并确认仅针对这个 App 的例外。
4. 再从“应用程序”文件夹打开 SpaceTrace。

不要全局关闭 Gatekeeper，也不要递归移除 quarantine 属性。
仅支持手动下载；此 Beta 不包含自动更新器。
替换版本后可能需要重新选择目录；目前不承诺回滚兼容。
NOTICE

/bin/chmod 644 "$temporary_output"
/bin/ln "$temporary_output" "$output_path" \
    || fail "output appeared concurrently"
/bin/rm -f -- "$temporary_output" || fail "could not finalize output"
temporary_output=""
