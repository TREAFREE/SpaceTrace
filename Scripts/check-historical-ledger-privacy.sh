#!/bin/zsh

set -euo pipefail

readonly plan_path="docs/superpowers/plans/2026-08-11-sqlite-v11-historical-ledger.md"
readonly released_fixture_root="Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
readonly released_fixture_manifest="${released_fixture_root}/manifest.json"
readonly released_fixture_verifier="Scripts/verify-released-schema-fixtures.sh"
readonly reviewed_manifest_v2_sha256="e196f7cff3b08f31f9b1ff4be0ecc37bb89460fd2c3e899a9b8211f0464e2da6"
readonly prior_reviewed_manifest_v2_sha256="8e11172b11f00e19af2627aa33ea8556a67f36b0526aa08553968770170f0201"
readonly second_prior_reviewed_manifest_v2_sha256="25fee3602653820e235a0cfa4d2b881bfa798cbdf531aba44d1882a547a2a93d"
readonly maximum_commit_count=4096
readonly maximum_artifact_count=20000
readonly maximum_artifact_bytes=$((32 * 1024 * 1024))
readonly maximum_total_bytes=$((512 * 1024 * 1024))
readonly maximum_enumerated_path_count=20000
readonly maximum_enumerated_path_bytes=$((64 * 1024 * 1024))
readonly maximum_swift_source_bytes=$((2 * 1024 * 1024))
readonly maximum_swift_parse_bytes=$((64 * 1024 * 1024))
readonly maximum_swift_parser_probe_bytes=$((1024 * 1024))

# The parse tree has no resolved receiver types. Keep member names deliberately
# fail-closed: an unrelated `.info`, `.error`, `.raise`, or signposter-shaped
# method is rejected until it is renamed or routed through a reviewed path-free
# wrapper. Global-only names stay separate so ordinary calls such as Data.write
# are not rejected.
typeset -gr swift_forbidden_global_sink_name='(?:Log''ger|OS''Signposter|os_''log|os_''logv|os_''log_(?:debug|info|error|fault)|os_''log_with_type|os_''signpost|os_''signpost_event_emit|os_''signpost_interval_(?:begin|end)|NS''Log|NS''Logv|CF''Show|pri''nt|du''mp|debug''Print|fatal''Error|precondition''Failure|assertion''Failure|assert|precondition|printf|vprintf|puts|fputs|fprintf|vfprintf|dprintf|vdprintf|fwrite|write|writev|perror|syslog|vsyslog)'
typeset -gr swift_forbidden_member_sink_name='(?:tr''ace|de''bug|in''fo|no''tice|warn''ing|er''ror|fa''ult|crit''ical|lo''g|standard''Error|standard''Output|raise|emit''Event|begin''Interval|end''Interval|with''IntervalSignpost)'
typeset -gr swift_forbidden_qualified_module_name='(?:Swift|Darwin|Glibc|Foundation|OSLog|os)'
typeset -gr swift_forbidden_decl_pattern="^[[:space:]]*\\([^\r\n]*unresolved_decl_ref_expr[^\r\n]*[[:space:]]name=\"${swift_forbidden_global_sink_name}\"(?:[[:space:]]|\\))"
typeset -gr swift_forbidden_member_pattern="^[[:space:]]*\\([^\r\n]*unresolved_dot_expr[^\r\n]*[[:space:]]field=\"${swift_forbidden_member_sink_name}\"(?:[[:space:]]|\\))"
typeset -gr swift_forbidden_qualified_pattern="^[[:space:]]*\\([^\r\n]*unresolved_dot_expr[^\r\n]*[[:space:]]field=\"${swift_forbidden_global_sink_name}\"[^\r\n]*\r?\n[[:space:]]*\\([^\r\n]*unresolved_decl_ref_expr[^\r\n]*[[:space:]]name=\"${swift_forbidden_qualified_module_name}\"(?:[[:space:]]|\\))"

infrastructure_failure() {
    print -u2 "historical ledger privacy gate: infrastructure failure"
    exit 2
}

for dependency in git rg shasum stat plutil file iconv awk sed find wc tr \
    cat dd id readlink mktemp rm swiftc; do
    command -v "$dependency" >/dev/null 2>&1 || infrastructure_failure
done

[[ -z ${SPACETRACE_HISTORICAL_LEDGER_PRIVACY_BASE:-} ]] || {
    print -u2 "historical ledger privacy gate: test base overrides are not accepted"
    exit 2
}

script_directory=${0:A:h}
repository_root=$(git -C "$script_directory" rev-parse --show-toplevel 2>/dev/null) || \
    infrastructure_failure
cd "$repository_root"

umask 077
temporary_root=$(mktemp -d /private/tmp/spacetrace-ledger-privacy.XXXXXX) || \
    infrastructure_failure
trap 'rm -rf -- "$temporary_root"' EXIT

artifact_count=0
total_materialized_bytes=0
enumerated_path_count=0
enumerated_path_bytes=0
typeset -gA manifest_fixture_paths
manifest_format_version=""
base_manifest_digest=""
base_manifest_available=false

report_violation() {
    local category=$1

    # Repository paths can themselves contain credentials or user data. Never
    # echo attacker-controlled names or matching content into CI diagnostics.
    print -u2 -r -- "historical ledger privacy gate: violation: $category"
    exit 1
}

validate_repository_path() {
    local repository_path=$1
    local repository_path_content="$temporary_root/repository-path"

    [[ -n "$repository_path" && "$repository_path" != /* ]] || \
        report_violation "invalid repository path"
    [[ "$repository_path" != *$'\n'* && "$repository_path" != *$'\r'* ]] || \
        report_violation "control character in repository path"
    print -rn -- "$repository_path" >"$repository_path_content"
    reject_credential_material "$repository_path_content" \
        "credential-shaped repository path"
}

account_artifact() {
    local byte_count=$1

    [[ "$byte_count" == <-> ]] || infrastructure_failure
    (( byte_count <= maximum_artifact_bytes )) || \
        report_violation "changed artifact exceeds the per-file scan bound"

    artifact_count=$((artifact_count + 1))
    total_materialized_bytes=$((total_materialized_bytes + byte_count))
    (( artifact_count <= maximum_artifact_count )) || \
        report_violation "changed artifact count exceeds the cumulative scan bound"
    (( total_materialized_bytes <= maximum_total_bytes )) || \
        report_violation "changed artifacts exceed the cumulative byte bound"
}

bounded_nul_path_consumer() {
    local output_path=$1
    local metadata_path=$2
    local remaining_count=$3
    local remaining_bytes=$4
    local LC_ALL=C
    local record
    local -i record_count=0
    local -i byte_count=0
    local -i record_bytes

    exec 3>"$output_path" || return 92
    while IFS= read -r -d '' record; do
        record_count=$((record_count + 1))
        record_bytes=$((${#record} + 1))
        byte_count=$((byte_count + record_bytes))
        if (( record_count > remaining_count )); then
            exec 3>&-
            return 90
        fi
        if (( byte_count > remaining_bytes )); then
            exec 3>&-
            return 91
        fi
        print -rn -u3 -- "$record"$'\0' || {
            exec 3>&-
            return 92
        }
    done
    exec 3>&-
    print -r -- "$record_count $byte_count" >"$metadata_path" || return 92
}

capture_nul_path_list() {
    local output_path=$1
    shift
    local metadata_path="$temporary_root/path-list-metadata"
    local -i remaining_count=$((maximum_enumerated_path_count - enumerated_path_count))
    local -i remaining_bytes=$((maximum_enumerated_path_bytes - enumerated_path_bytes))
    local -a pipeline_status
    local captured_count
    local captured_bytes

    (( remaining_count >= 0 && remaining_bytes >= 0 )) || \
        report_violation "enumerated repository paths exceed their cumulative bound"
    : >"$metadata_path"
    if "$@" 2>/dev/null | \
        bounded_nul_path_consumer "$output_path" "$metadata_path" \
            "$remaining_count" "$remaining_bytes"; then
        pipeline_status=("${pipestatus[@]}")
    else
        pipeline_status=("${pipestatus[@]}")
    fi

    case ${pipeline_status[2]:-92} in
        0) ;;
        90) report_violation "enumerated repository path count exceeds its cumulative bound" ;;
        91) report_violation "enumerated repository path bytes exceed their cumulative bound" ;;
        *) infrastructure_failure ;;
    esac
    (( ${pipeline_status[1]:-1} == 0 )) || infrastructure_failure

    IFS=' ' read -r captured_count captured_bytes <"$metadata_path" || \
        infrastructure_failure
    [[ "$captured_count" == <-> && "$captured_bytes" == <-> ]] || \
        infrastructure_failure
    enumerated_path_count=$((enumerated_path_count + captured_count))
    enumerated_path_bytes=$((enumerated_path_bytes + captured_bytes))
}

regex_matches() {
    local multiline=$1
    local pattern=$2
    local content_path=$3
    local exit_status=0
    local -a arguments=(--quiet --no-messages --pcre2)

    [[ "$multiline" == true ]] && arguments+=(--multiline)
    rg "${arguments[@]}" -- "$pattern" "$content_path" || exit_status=$?
    case "$exit_status" in
        0) return 0 ;;
        1) return 1 ;;
        *) infrastructure_failure ;;
    esac
}

fixed_string_matches() {
    local needle=$1
    local content_path=$2
    local exit_status=0

    rg --quiet --no-messages --fixed-strings -- "$needle" "$content_path" || exit_status=$?
    case "$exit_status" in
        0) return 0 ;;
        1) return 1 ;;
        *) infrastructure_failure ;;
    esac
}

resolve_scan_base() {
    local commits_path="$temporary_root/plan-commits"
    local plan_commit
    local resolved_base

    git log --max-count=2 --diff-filter=A --format='%H' -- "$plan_path" \
        >"$commits_path" 2>/dev/null || infrastructure_failure
    plan_commit=$(sed -n '1p' "$commits_path") || infrastructure_failure
    [[ -n "$plan_commit" ]] || {
        print -u2 "historical ledger privacy gate: plan-add commit is unavailable"
        exit 2
    }
    [[ $(wc -l <"$commits_path" | tr -d '[:space:]') == 1 ]] || {
        print -u2 "historical ledger privacy gate: plan boundary is ambiguous"
        exit 2
    }
    resolved_base=$(git rev-parse --verify "${plan_commit}^" 2>/dev/null) || {
        print -u2 "historical ledger privacy gate: plan-add parent is unavailable"
        exit 2
    }
    git merge-base --is-ancestor "$resolved_base" HEAD >/dev/null 2>&1 || {
        print -u2 "historical ledger privacy gate: plan-add parent is not an ancestor of HEAD"
        exit 2
    }
    print -r -- "$resolved_base"
}

require_regular_fixture_file() {
    local view=$1
    local reference=$2
    local repository_path=$3
    local expected_mode=${4:-100644}
    local lookup_path="$temporary_root/regular-file-lookup"
    local mode
    local object_type
    local object_id
    local stage
    local ignored_path

    case "$view" in
        commit)
            git ls-tree --format='%(objectmode) %(objecttype) %(objectname)' \
                "$reference" -- "$repository_path" >"$lookup_path" 2>/dev/null || \
                infrastructure_failure
            [[ -s "$lookup_path" ]] || \
                report_violation "released-schema artifact is absent"
            IFS=' ' read -r mode object_type object_id <"$lookup_path" || \
                infrastructure_failure
            [[ "$mode" == "$expected_mode" && "$object_type" == blob ]] || \
                report_violation "released-schema artifact is not a regular file"
            ;;
        index)
            git ls-files --stage -- "$repository_path" >"$lookup_path" 2>/dev/null || \
                infrastructure_failure
            [[ -s "$lookup_path" ]] || \
                report_violation "released-schema artifact is absent"
            IFS=$' \t' read -r mode object_id stage ignored_path <"$lookup_path" || \
                infrastructure_failure
            [[ "$mode" == "$expected_mode" && "$stage" == 0 ]] || \
                report_violation "released-schema artifact is not a regular file"
            ;;
        worktree)
            [[ -f "$repository_path" && ! -L "$repository_path" ]] || \
                report_violation "released-schema artifact is not a regular file"
            if [[ "$expected_mode" == 100755 ]]; then
                [[ -x "$repository_path" ]] || \
                    report_violation "released-schema artifact mode is invalid"
            else
                [[ ! -x "$repository_path" ]] || \
                    report_violation "released-schema artifact mode is invalid"
            fi
            ;;
        *) infrastructure_failure ;;
    esac
}

materialize_commit_blob() {
    local commit=$1
    local repository_path=$2
    local destination=$3
    local lookup_path="$temporary_root/commit-lookup"
    local mode
    local object_type
    local object_id
    local byte_count

    validate_repository_path "$repository_path"
    git ls-tree --format='%(objectmode) %(objecttype) %(objectname)' \
        "$commit" -- "$repository_path" >"$lookup_path" 2>/dev/null || \
        infrastructure_failure
    [[ -s "$lookup_path" ]] || return 1
    IFS=' ' read -r mode object_type object_id <"$lookup_path" || \
        infrastructure_failure
    [[ "$object_type" == blob ]] || \
        report_violation "unsupported non-blob historical object"
    [[ "$mode" == 100644 || "$mode" == 100755 || "$mode" == 120000 ]] || \
        report_violation "unsupported historical object mode"

    byte_count=$(git cat-file -s "$object_id" 2>/dev/null) || \
        infrastructure_failure
    account_artifact "$byte_count"
    git cat-file blob "$object_id" >"$destination" 2>/dev/null || \
        infrastructure_failure
    return 0
}

materialize_index_blob() {
    local repository_path=$1
    local destination=$2
    local lookup_path="$temporary_root/index-lookup"
    local mode
    local object_id
    local stage
    local ignored_path
    local byte_count

    validate_repository_path "$repository_path"
    git ls-files --stage -- "$repository_path" >"$lookup_path" 2>/dev/null || \
        infrastructure_failure
    [[ -s "$lookup_path" ]] || return 1
    IFS=$' \t' read -r mode object_id stage ignored_path <"$lookup_path" || \
        infrastructure_failure
    [[ "$stage" == 0 ]] || report_violation "unresolved index entry"
    [[ "$mode" == 100644 || "$mode" == 100755 || "$mode" == 120000 ]] || \
        report_violation "unsupported staged object mode"

    byte_count=$(git cat-file -s "$object_id" 2>/dev/null) || \
        infrastructure_failure
    account_artifact "$byte_count"
    git cat-file blob "$object_id" >"$destination" 2>/dev/null || \
        infrastructure_failure
    return 0
}

materialize_worktree_file() {
    local repository_path=$1
    local destination=$2
    local byte_count
    local link_target
    local link_target_after
    local source_fd
    local initial_state
    local opened_state
    local final_fd_state
    local final_path_state
    local actual_byte_count

    validate_repository_path "$repository_path"
    [[ -e "$repository_path" || -L "$repository_path" ]] || return 1

    if [[ -L "$repository_path" ]]; then
        link_target=$(readlink "$repository_path" 2>/dev/null) || \
            infrastructure_failure
        byte_count=$(print -rn -- "$link_target" | wc -c | tr -d '[:space:]')
        account_artifact "$byte_count"
        print -rn -- "$link_target" >"$destination"
        [[ -L "$repository_path" ]] || infrastructure_failure
        link_target_after=$(readlink "$repository_path" 2>/dev/null) || \
            infrastructure_failure
        [[ "$link_target_after" == "$link_target" ]] || infrastructure_failure
    elif [[ -f "$repository_path" ]]; then
        initial_state=$(stat -f '%i:%z:%Fm:%Fc' "$repository_path" 2>/dev/null) || \
            infrastructure_failure
        if ! { exec {source_fd}<"$repository_path"; } \
            2>"$temporary_root/worktree-open-errors"; then
            infrastructure_failure
        fi
        opened_state=$(stat -L -f '%i:%z:%Fm:%Fc' "/dev/fd/$source_fd" \
            2>/dev/null) || infrastructure_failure
        [[ "$opened_state" == "$initial_state" ]] || infrastructure_failure
        byte_count=${${opened_state#*:}%%:*}
        account_artifact "$byte_count"
        command dd bs=1048576 count=33 <&$source_fd >"$destination" \
            2>"$temporary_root/worktree-read-errors" || \
            infrastructure_failure
        actual_byte_count=$(stat -f '%z' "$destination" 2>/dev/null) || \
            infrastructure_failure
        [[ "$actual_byte_count" == <-> ]] || infrastructure_failure
        (( actual_byte_count <= maximum_artifact_bytes )) || \
            report_violation "changed artifact exceeds the per-file scan bound"
        [[ "$actual_byte_count" == "$byte_count" ]] || infrastructure_failure
        final_fd_state=$(stat -L -f '%i:%z:%Fm:%Fc' "/dev/fd/$source_fd" \
            2>/dev/null) || infrastructure_failure
        [[ -f "$repository_path" && ! -L "$repository_path" ]] || \
            infrastructure_failure
        final_path_state=$(stat -f '%i:%z:%Fm:%Fc' "$repository_path" \
            2>/dev/null) || infrastructure_failure
        [[ "$final_fd_state" == "$opened_state" && \
           "$final_path_state" == "$opened_state" ]] || infrastructure_failure
        exec {source_fd}<&-
    else
        report_violation "unsupported worktree object"
    fi
    return 0
}

materialize_view_file() {
    local view=$1
    local reference=$2
    local repository_path=$3
    local destination=$4

    case "$view" in
        commit) materialize_commit_blob "$reference" "$repository_path" "$destination" ;;
        index) materialize_index_blob "$repository_path" "$destination" ;;
        worktree) materialize_worktree_file "$repository_path" "$destination" ;;
        *) infrastructure_failure ;;
    esac
}

is_binary_file() {
    local repository_path=$1
    local content_path=$2
    local encoding
    local exit_status=0

    case "$repository_path" in
        *.sqlite|*.sqlite3|*.db|*.png|*.jpg|*.jpeg|*.gif|*.zip|*.gz|*.xz|*.dmg)
            return 0
            ;;
    esac

    encoding=$(file -b --mime-encoding -- "$content_path" 2>/dev/null) || \
        infrastructure_failure
    case "$encoding" in
        binary|unknown-8bit) return 0 ;;
    esac

    iconv -f UTF-8 -t UTF-8 <"$content_path" \
        >"$temporary_root/utf8-validation" 2>/dev/null || exit_status=$?
    (( exit_status == 0 )) || return 0
    return 1
}

plist_value() {
    local manifest_path=$1
    local key_path=$2
    local value

    value=$(plutil -extract "$key_path" raw -o - "$manifest_path" 2>/dev/null) || \
        report_violation "malformed released-schema manifest"
    print -r -- "$value"
}

valid_lowercase_sha256() {
    local value=$1

    (( ${#value} == 64 )) && [[ "$value" != *[^0-9a-f]* ]]
}

validate_manifest_file() {
    local manifest_path=$1
    local view=$2
    local reference=$3
    local format_version
    local fixture_count
    local manifest_digest
    local index
    local relative_path
    local version_directory
    local schema_version
    local expected_digest
    local binary_path
    local binary_content="$temporary_root/fixture-content"
    local actual_digest
    local generator_path
    local generator_digest
    local generator_content="$temporary_root/generator-content"
    local actual_generator_digest

    manifest_fixture_paths=()
    format_version=$(plist_value "$manifest_path" formatVersion)
    manifest_format_version=$format_version
    fixture_count=$(plist_value "$manifest_path" fixtures)
    [[ "$format_version" == 1 || "$format_version" == 2 ]] || \
        report_violation "unsupported released-schema manifest format"
    [[ "$fixture_count" == <-> ]] || \
        report_violation "released-schema manifest fixture count is invalid"
    (( fixture_count <= 128 )) || \
        report_violation "released-schema manifest fixture count exceeds its bound"

    if [[ "$format_version" == 1 ]]; then
        [[ "$base_manifest_available" == true ]] || \
            report_violation "new format-1 fixture manifests are not accepted"
        manifest_digest=$(shasum -a 256 "$manifest_path" | awk '{print $1}') || \
            infrastructure_failure
        [[ "$manifest_digest" == "$base_manifest_digest" ]] || \
            report_violation "format-1 fixture manifest differs from the frozen plan base"
    else
        manifest_digest=$(shasum -a 256 "$manifest_path" | awk '{print $1}') || \
            infrastructure_failure
        if [[ "$manifest_digest" == "$reviewed_manifest_v2_sha256" ]]; then
            (( fixture_count == 4 )) || \
                report_violation "format-2 fixture closure is incomplete"
        elif [[ "$manifest_digest" == "$prior_reviewed_manifest_v2_sha256" ]]; then
            (( fixture_count == 3 )) || \
                report_violation "format-2 fixture closure is incomplete"
        elif [[ "$manifest_digest" == "$second_prior_reviewed_manifest_v2_sha256" ]]; then
            (( fixture_count == 2 )) || \
                report_violation "format-2 fixture closure is incomplete"
        else
            report_violation "format-2 fixture manifest is not independently reviewed"
        fi
    fi

    for (( index = 0; index < fixture_count; index++ )); do
        relative_path=$(plist_value "$manifest_path" "fixtures.${index}.relativePath")
        schema_version=$(plist_value "$manifest_path" "fixtures.${index}.schemaVersion")
        expected_digest=$(plist_value "$manifest_path" "fixtures.${index}.sha256")

        case "$relative_path" in
            v<->/SpaceTrace.sqlite) ;;
            *) report_violation "released-schema fixture path is not canonical" ;;
        esac
        version_directory=${relative_path%%/*}
        [[ "$schema_version" == "${version_directory#v}" ]] || \
            report_violation "fixture schema version disagrees with its path"
        valid_lowercase_sha256 "$expected_digest" || \
            report_violation "fixture digest is invalid"
        [[ -z ${manifest_fixture_paths[$relative_path]:-} ]] || \
            report_violation "duplicate released-schema fixture entry"
        manifest_fixture_paths[$relative_path]=1

        binary_path="${released_fixture_root}/${relative_path}"
        require_regular_fixture_file "$view" "$reference" "$binary_path"
        materialize_view_file "$view" "$reference" "$binary_path" \
            "$binary_content" || \
            report_violation "manifested fixture is absent in the same repository view"
        is_binary_file "$binary_path" "$binary_content" || \
            report_violation "released-schema fixture is not binary"
        actual_digest=$(shasum -a 256 "$binary_content" | awk '{print $1}') || \
            infrastructure_failure
        [[ "$actual_digest" == "$expected_digest" ]] || \
            report_violation "released-schema fixture digest mismatch"

        if [[ "$format_version" == 2 ]]; then
            generator_path=$(plist_value "$manifest_path" "fixtures.${index}.generatorPath")
            generator_digest=$(plist_value "$manifest_path" "fixtures.${index}.generatorSHA256")
            [[ "$generator_path" == \
                "Scripts/Fixtures/generate-released-schema-v${schema_version}-fixture.sh" ]] || \
                report_violation "released-schema generator path is not canonical"
            valid_lowercase_sha256 "$generator_digest" || \
                report_violation "released-schema generator digest is invalid"
            require_regular_fixture_file "$view" "$reference" "$generator_path" 100755
            materialize_view_file "$view" "$reference" "$generator_path" \
                "$generator_content" || \
                report_violation "released-schema generator is absent in the same repository view"
            actual_generator_digest=$(shasum -a 256 "$generator_content" | awk '{print $1}') || \
                infrastructure_failure
            [[ "$actual_generator_digest" == "$generator_digest" ]] || \
                report_violation "released-schema generator digest mismatch"
        fi
    done
}

enumerate_view_fixtures() {
    local view=$1
    local reference=$2
    local output_path=$3
    local traversed_paths="$temporary_root/traversed-fixture-paths"
    local traversed_path

    case "$view" in
        commit)
            capture_nul_path_list "$output_path" git ls-tree -r -z --name-only \
                "$reference" -- "$released_fixture_root"
            ;;
        index)
            capture_nul_path_list "$output_path" git ls-files -z -- \
                "$released_fixture_root"
            ;;
        worktree)
            : >"$output_path" || infrastructure_failure
            if [[ -e "$released_fixture_root" || -L "$released_fixture_root" ]]; then
                [[ -d "$released_fixture_root" && ! -L "$released_fixture_root" ]] || \
                    report_violation "released-schema fixture root is not a directory"
                capture_nul_path_list "$traversed_paths" find \
                    "$released_fixture_root" -print0
                while IFS= read -r -d '' traversed_path; do
                    [[ "${traversed_path:t}" == SpaceTrace.sqlite ]] || continue
                    [[ -f "$traversed_path" || -L "$traversed_path" ]] || continue
                    print -rn -- "$traversed_path"$'\0' >>"$output_path" || \
                        infrastructure_failure
                done <"$traversed_paths"
            fi
            ;;
        *) infrastructure_failure ;;
    esac
}

validate_fixture_closure() {
    local view=$1
    local reference=$2
    local manifest_content="$temporary_root/manifest-content"
    local fixture_paths="$temporary_root/fixture-paths"
    local repository_path
    local relative_path
    local manifest_present=false
    local legacy_content="$temporary_root/legacy-fixture-content"
    local legacy_digest
    local expected_legacy_digest

    if materialize_view_file "$view" "$reference" "$released_fixture_manifest" \
        "$manifest_content"; then
        manifest_present=true
        require_regular_fixture_file "$view" "$reference" \
            "$released_fixture_manifest"
        is_binary_file "$released_fixture_manifest" "$manifest_content" && \
            report_violation "released-schema manifest is not text"
        scan_text_file "$released_fixture_manifest" "$manifest_content"
        validate_manifest_file "$manifest_content" "$view" "$reference"
    elif [[ "$base_manifest_available" == true ]]; then
        report_violation "released-schema manifest is absent"
    fi

    enumerate_view_fixtures "$view" "$reference" "$fixture_paths"
    while IFS= read -r -d '' repository_path; do
        validate_repository_path "$repository_path"
        [[ "$repository_path" == "$released_fixture_manifest" ]] && continue
        [[ "$manifest_present" == true ]] || \
            report_violation "binary fixture has no sibling manifest"
        relative_path=${repository_path#${released_fixture_root}/}
        case "$relative_path" in
            v<->/SpaceTrace.sqlite) ;;
            *) report_violation "released-schema fixture path is not canonical" ;;
        esac
        if [[ -z ${manifest_fixture_paths[$relative_path]:-} ]]; then
            case "$manifest_format_version:$relative_path" in
                2:v6/SpaceTrace.sqlite)
                    expected_legacy_digest=5a5bbe6cdf57ac6c5e4398a771b6505e29e4775b4f321fd5ed1097ff30bae528 ;;
                2:v7/SpaceTrace.sqlite)
                    expected_legacy_digest=beccfcbf1bf40ad2f3f89997d58f61aeacb7b0126ed9a4c813b9448a3cdfb95c ;;
                2:v8/SpaceTrace.sqlite)
                    expected_legacy_digest=8d2d9468362f685e8e485ae291d007c0b70aaf06d691dd8ff2f50c2de506eeb5 ;;
                2:v9/SpaceTrace.sqlite)
                    expected_legacy_digest=fdc8a4452202260b6bbefd47c122c60e98ad7a959f184646a06ed067817c7108 ;;
                *) report_violation "binary fixture is absent from its manifest" ;;
            esac
            require_regular_fixture_file "$view" "$reference" "$repository_path"
            materialize_view_file "$view" "$reference" "$repository_path" \
                "$legacy_content" || \
                report_violation "frozen legacy fixture is absent"
            legacy_digest=$(shasum -a 256 "$legacy_content" | awk '{print $1}') || \
                infrastructure_failure
            [[ "$legacy_digest" == "$expected_legacy_digest" ]] || \
                report_violation "frozen legacy fixture digest mismatch"
        fi
    done <"$fixture_paths"
}

reject_credential_material() {
    local content_path=$1
    local violation_category=$2
    local github_token_prefix='g''h'
    local fine_grained_prefix='github''_pat_'
    local pem_begin='-----BEGIN '
    local private_key_label='PRIVATE'' KEY-----'
    local open_ssh_label='OPEN''SSH PRIVATE KEY-----'
    local secret_pattern
    local -a secret_patterns=(
        "${github_token_prefix}(?:p|o|u|s|r)_[A-Za-z0-9]{20,}"
        "${fine_grained_prefix}[A-Za-z0-9_]{20,}"
        '(?:AKIA|ASIA)[0-9A-Z]{16}'
        "${pem_begin}(?:${open_ssh_label}|(?:RSA |EC |DSA |ENCRYPTED )?${private_key_label})"
    )

    for secret_pattern in "${secret_patterns[@]}"; do
        if regex_matches false "$secret_pattern" "$content_path"; then
            report_violation "$violation_category"
        fi
    done
}

validate_swift_parser() {
    local probe_source="$temporary_root/swift-parser-probe.swift"
    local probe_tree="$temporary_root/swift-parser-probe-tree"
    local probe_status=0
    local -i parse_file_blocks=$((maximum_swift_parser_probe_bytes / 512))

    print -r -- 'let spacetraceParserProbe = Logger()' >"$probe_source"
    print -r -- 'spacetraceParserProbe.info("probe")' >>"$probe_source"
    print -r -- 'Darwin.write(2, "probe", 5)' >>"$probe_source"
    (
        ulimit -f "$parse_file_blocks"
        swiftc -frontend -dump-parse -
    ) <"$probe_source" >"$probe_tree" 2>/dev/null || probe_status=$?
    (( probe_status == 0 )) || infrastructure_failure
    fixed_string_matches '(source_file "<stdin>"' "$probe_tree" || \
        infrastructure_failure
    fixed_string_matches '"spacetraceParserProbe"' "$probe_tree" || \
        infrastructure_failure
    regex_matches false "$swift_forbidden_decl_pattern" "$probe_tree" || \
        infrastructure_failure
    regex_matches false "$swift_forbidden_member_pattern" "$probe_tree" || \
        infrastructure_failure
    regex_matches true "$swift_forbidden_qualified_pattern" "$probe_tree" || \
        infrastructure_failure
}

reject_swift_diagnostic_sinks() {
    local content_path=$1
    local parse_tree="$temporary_root/swift-parse-tree"
    local syntax_status=0
    local parse_status=0
    local source_bytes
    local parse_bytes
    local -i parse_file_blocks=$((maximum_swift_parse_bytes / 512))

    source_bytes=$(stat -f '%z' "$content_path" 2>/dev/null) || \
        infrastructure_failure
    [[ "$source_bytes" == <-> ]] || infrastructure_failure
    (( source_bytes <= maximum_swift_source_bytes )) || \
        report_violation "Swift source exceeds its parser input bound"

    swiftc -frontend -parse - <"$content_path" >/dev/null 2>/dev/null || \
        syntax_status=$?
    case "$syntax_status" in
        0) ;;
        1) report_violation \
            "Swift source cannot be parsed for diagnostic-sink validation" ;;
        *) infrastructure_failure ;;
    esac

    (
        ulimit -f "$parse_file_blocks"
        swiftc -frontend -dump-parse -
    ) <"$content_path" >"$parse_tree" 2>/dev/null || parse_status=$?
    parse_bytes=$(stat -f '%z' "$parse_tree" 2>/dev/null) || \
        infrastructure_failure
    [[ "$parse_bytes" == <-> ]] || infrastructure_failure
    (( parse_bytes <= maximum_swift_parse_bytes )) || \
        report_violation "Swift parse evidence exceeds its scan bound"
    if (( parse_status != 0 && parse_bytes >= maximum_swift_parse_bytes )); then
        report_violation "Swift parse evidence exceeds its scan bound"
    fi
    case "$parse_status" in
        0|1) ;;
        *) infrastructure_failure ;;
    esac

    if regex_matches false "$swift_forbidden_decl_pattern" "$parse_tree" || \
       regex_matches false "$swift_forbidden_member_pattern" "$parse_tree" || \
       regex_matches true "$swift_forbidden_qualified_pattern" "$parse_tree"; then
        report_violation "direct diagnostic sink requires a reviewed path-free wrapper"
    fi
}

scan_text_file() {
    local repository_path=$1
    local content_path=$2
    local mac_user_prefix='/''Users/'
    local mac_path_boundary="(?:/|(?=\$|[[:space:]\"'<>),;]))"
    local mac_user_pattern="${mac_user_prefix}[^/[:space:]\\\"'<>]+${mac_path_boundary}"
    local non_synthetic_mac_user_pattern="${mac_user_prefix}(?!(?:example|alex|renamed-account|测试)${mac_path_boundary})[^/[:space:]\\\"'<>]+${mac_path_boundary}"
    local current_user
    local current_user_pattern

    reject_credential_material "$content_path" \
        "credential or private-key material"

    current_user=$(id -un 2>/dev/null) || infrastructure_failure
    current_user_pattern="${mac_user_prefix}\\Q${current_user}\\E${mac_path_boundary}"
    if regex_matches false "$current_user_pattern" "$content_path"; then
        report_violation "current macOS user path"
    fi
    if [[ -n ${HOME:-} && "$HOME" != / ]] && \
        fixed_string_matches "$HOME" "$content_path"; then
        report_violation "current home path"
    fi

    if regex_matches false "$mac_user_pattern" "$content_path"; then
        case "$repository_path" in
            Packages/SpaceTraceKit/Tests/*|Scripts/Tests/*)
                if regex_matches false "$non_synthetic_mac_user_pattern" \
                    "$content_path"; then
                    report_violation "real macOS user path"
                fi
                ;;
            *) report_violation "macOS user path outside a synthetic test fixture" ;;
        esac
    fi

    case "$repository_path" in
        *.swift) reject_swift_diagnostic_sinks "$content_path" ;;
    esac
}

scan_materialized_file() {
    local repository_path=$1
    local content_path=$2

    if is_binary_file "$repository_path" "$content_path"; then
        case "$repository_path" in
            "$released_fixture_root"/v<->/SpaceTrace.sqlite) ;;
            *) report_violation "unreviewed binary artifact" ;;
        esac
    else
        scan_text_file "$repository_path" "$content_path"
    fi
}

scan_commit_path() {
    local commit=$1
    local repository_path=$2
    local content_path="$temporary_root/content"

    if materialize_commit_blob "$commit" "$repository_path" "$content_path"; then
        scan_materialized_file "$repository_path" "$content_path"
    fi
}

scan_index_path() {
    local repository_path=$1
    local content_path="$temporary_root/content"

    if materialize_index_blob "$repository_path" "$content_path"; then
        scan_materialized_file "$repository_path" "$content_path"
    fi
}

scan_worktree_path() {
    local repository_path=$1
    local content_path="$temporary_root/content"

    if materialize_worktree_file "$repository_path" "$content_path"; then
        scan_materialized_file "$repository_path" "$content_path"
    fi
}

reject_hidden_index_flags() {
    local flags_path="$temporary_root/index-flags"
    local record
    local tag

    capture_nul_path_list "$flags_path" git ls-files -v -z
    while IFS= read -r -d '' record; do
        tag=${record[1,1]}
        if [[ "$tag" == S || "$tag" == [[:lower:]] ]]; then
            report_violation "index flag can hide worktree changes"
        fi
    done <"$flags_path"
}

validate_git_history_view() {
    local replace_refs="$temporary_root/replace-refs"
    local shallow_state
    local grafts_path

    git replace -l >"$replace_refs" 2>/dev/null || infrastructure_failure
    [[ ! -s "$replace_refs" ]] || \
        report_violation "Git replacement refs can hide cumulative history"
    grafts_path=$(git rev-parse --git-path info/grafts 2>/dev/null) || \
        infrastructure_failure
    [[ ! -s "$grafts_path" ]] || \
        report_violation "Git grafts can hide cumulative history"
    shallow_state=$(git rev-parse --is-shallow-repository 2>/dev/null) || \
        infrastructure_failure
    [[ "$shallow_state" == false ]] || {
        print -u2 "historical ledger privacy gate: complete Git history is required"
        exit 2
    }
    export GIT_NO_REPLACE_OBJECTS=1
}

validate_git_history_view
validate_swift_parser
scan_base=$(resolve_scan_base) || infrastructure_failure
readonly scan_base

base_manifest_content="$temporary_root/base-manifest"
if materialize_commit_blob "$scan_base" "$released_fixture_manifest" \
    "$base_manifest_content"; then
    require_regular_fixture_file commit "$scan_base" \
        "$released_fixture_manifest"
    base_manifest_available=true
    base_manifest_digest=$(shasum -a 256 "$base_manifest_content" | awk '{print $1}') || \
        infrastructure_failure
    base_format=$(plist_value "$base_manifest_content" formatVersion)
    base_count=$(plist_value "$base_manifest_content" fixtures)
    [[ "$base_format" == 1 && "$base_count" == <-> ]] || \
        report_violation "plan-base fixture manifest is not the frozen format"
fi

if [[ -f "$released_fixture_manifest" && ! -L "$released_fixture_manifest" ]]; then
    current_manifest_format=$(plist_value "$released_fixture_manifest" formatVersion)
    if [[ "$current_manifest_format" == 2 ]]; then
        [[ -f "$released_fixture_verifier" && ! -L "$released_fixture_verifier" ]] || \
            report_violation "format-2 fixture verifier is absent"
        /bin/bash "$released_fixture_verifier" >/dev/null 2>&1 || \
            report_violation "format-2 fixture verifier rejected the current closure"
    fi
fi

reject_hidden_index_flags

commit_list="$temporary_root/commits"
git rev-list --max-count=$((maximum_commit_count + 1)) --reverse \
    "${scan_base}..HEAD" >"$commit_list" 2>/dev/null || \
    infrastructure_failure
commit_count=$(wc -l <"$commit_list" | tr -d '[:space:]')
[[ "$commit_count" == <-> ]] || infrastructure_failure
(( commit_count <= maximum_commit_count )) || \
    report_violation "commit count exceeds the cumulative scan bound"

while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    commit_paths="$temporary_root/commit-paths"
    capture_nul_path_list "$commit_paths" git diff-tree -m --root \
        --no-commit-id --name-only -r -z "$commit" --
    typeset -A seen_commit_paths
    seen_commit_paths=()
    while IFS= read -r -d '' repository_path; do
        [[ -z ${seen_commit_paths[$repository_path]:-} ]] || continue
        seen_commit_paths[$repository_path]=1
        scan_commit_path "$commit" "$repository_path"
    done <"$commit_paths"
    validate_fixture_closure commit "$commit"
done <"$commit_list"

staged_paths="$temporary_root/staged-paths"
capture_nul_path_list "$staged_paths" git diff --cached --name-only \
    --diff-filter=ACMRD -z --
while IFS= read -r -d '' repository_path; do
    scan_index_path "$repository_path"
done <"$staged_paths"
validate_fixture_closure index ""

unstaged_paths="$temporary_root/unstaged-paths"
capture_nul_path_list "$unstaged_paths" git diff --name-only \
    --diff-filter=ACMRD -z --
while IFS= read -r -d '' repository_path; do
    scan_worktree_path "$repository_path"
done <"$unstaged_paths"

untracked_paths="$temporary_root/untracked-paths"
capture_nul_path_list "$untracked_paths" git ls-files --others \
    --exclude-standard -z --
while IFS= read -r -d '' repository_path; do
    scan_worktree_path "$repository_path"
done <"$untracked_paths"
validate_fixture_closure worktree ""

print "Historical ledger privacy boundaries are valid."
