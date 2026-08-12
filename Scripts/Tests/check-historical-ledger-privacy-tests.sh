#!/usr/bin/env bash

set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_directory/../.." && pwd -P)
production_checker="$repository_root/Scripts/check-historical-ledger-privacy.sh"

if [[ ! -f "$production_checker" ]]; then
    printf 'RED: production checker is missing: Scripts/check-historical-ledger-privacy.sh\n' >&2
    exit 1
fi

temporary_root=$(mktemp -d /private/tmp/spacetrace-ledger-privacy-tests.XXXXXX)
trap 'rm -rf -- "$temporary_root"' EXIT

current_repository=""
current_base=""
passed_cases=0
failed_cases=0
real_git=$(command -v git)
plan_path="docs/superpowers/plans/2026-08-11-sqlite-v11-historical-ledger.md"

fail() {
    printf 'privacy checker contract test failed: %s\n' "$1" >&2
    exit 1
}

record_contract_failure() {
    local label=$1
    local detail=$2

    printf 'RED: %s: %s\n' "$label" "$detail" >&2
    failed_cases=$((failed_cases + 1))
}

create_repository() {
    local label=$1

    current_repository="$temporary_root/$label"
    mkdir -p "$current_repository/Scripts" "$current_repository/Sources"
    git -C "$current_repository" init -q
    git -C "$current_repository" config user.name "SpaceTrace Synthetic Test"
    git -C "$current_repository" config user.email "spacetrace-test@example.invalid"
    git -C "$current_repository" config commit.gpgsign false

    cp "$production_checker" \
        "$current_repository/Scripts/check-historical-ledger-privacy.sh"
    chmod +x "$current_repository/Scripts/check-historical-ledger-privacy.sh"
    printf 'synthetic privacy-checker contract repository\n' \
        >"$current_repository/README.md"
    git -C "$current_repository" add README.md Scripts/check-historical-ledger-privacy.sh
    git -C "$current_repository" commit -qm "install synthetic checker harness"
    mkdir -p "$current_repository/${plan_path%/*}"
    printf '# Synthetic historical-ledger plan boundary\n' \
        >"$current_repository/$plan_path"
    git -C "$current_repository" add "$plan_path"
    git -C "$current_repository" commit -qm "add synthetic plan boundary"
}

create_repository_with_legacy_v1_fixture() {
    local label=$1
    local fixture_root
    local fixture_digest

    current_repository="$temporary_root/$label"
    mkdir -p "$current_repository/Scripts" "$current_repository/Sources"
    git -C "$current_repository" init -q
    git -C "$current_repository" config user.name "SpaceTrace Synthetic Test"
    git -C "$current_repository" config user.email "spacetrace-test@example.invalid"
    git -C "$current_repository" config commit.gpgsign false
    cp "$production_checker" \
        "$current_repository/Scripts/check-historical-ledger-privacy.sh"
    chmod +x "$current_repository/Scripts/check-historical-ledger-privacy.sh"
    printf 'synthetic privacy-checker contract repository\n' \
        >"$current_repository/README.md"

    fixture_root="$current_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
    mkdir -p "$fixture_root/v9"
    printf '\000SQLite format 3\000synthetic-legacy-v9-fixture\000' \
        >"$fixture_root/v9/SpaceTrace.sqlite"
    fixture_digest=$(shasum -a 256 \
        "$fixture_root/v9/SpaceTrace.sqlite" | awk '{print $1}')
    write_released_fixture_manifest "$fixture_root/manifest.json" 9 \
        "v9/SpaceTrace.sqlite" "$fixture_digest"
    git -C "$current_repository" add -A
    git -C "$current_repository" commit -qm "install legacy fixture and checker harness"

    mkdir -p "$current_repository/${plan_path%/*}"
    printf '# Synthetic historical-ledger plan boundary\n' \
        >"$current_repository/$plan_path"
    git -C "$current_repository" add "$plan_path"
    git -C "$current_repository" commit -qm "add synthetic plan boundary"
}

create_bounded_repository() {
    local label=$1
    local commit_limit=$2
    local artifact_limit=$3
    local total_byte_limit=$4
    local path_limit=$5
    local path_byte_limit=$6
    local preboundary_path_count=$7
    local swift_source_limit=${8:-2097152}
    local swift_parse_limit=${9:-67108864}
    local checker_destination
    local index

    current_repository="$temporary_root/$label"
    mkdir -p "$current_repository/Scripts" "$current_repository/Sources"
    git -C "$current_repository" init -q
    git -C "$current_repository" config user.name "SpaceTrace Synthetic Test"
    git -C "$current_repository" config user.email "spacetrace-test@example.invalid"
    git -C "$current_repository" config commit.gpgsign false

    checker_destination="$current_repository/Scripts/check-historical-ledger-privacy.sh"
    awk -v commit_limit="$commit_limit" \
        -v artifact_limit="$artifact_limit" \
        -v total_byte_limit="$total_byte_limit" \
        -v path_limit="$path_limit" \
        -v path_byte_limit="$path_byte_limit" \
        -v swift_source_limit="$swift_source_limit" \
        -v swift_parse_limit="$swift_parse_limit" '
        /^readonly maximum_commit_count=/ {
            print "readonly maximum_commit_count=" commit_limit; next
        }
        /^readonly maximum_artifact_count=/ {
            print "readonly maximum_artifact_count=" artifact_limit; next
        }
        /^readonly maximum_total_bytes=/ {
            print "readonly maximum_total_bytes=" total_byte_limit; next
        }
        /^readonly maximum_enumerated_path_count=/ {
            print "readonly maximum_enumerated_path_count=" path_limit; next
        }
        /^readonly maximum_enumerated_path_bytes=/ {
            print "readonly maximum_enumerated_path_bytes=" path_byte_limit; next
        }
        /^readonly maximum_swift_source_bytes=/ {
            print "readonly maximum_swift_source_bytes=" swift_source_limit; next
        }
        /^readonly maximum_swift_parse_bytes=/ {
            print "readonly maximum_swift_parse_bytes=" swift_parse_limit; next
        }
        { print }
    ' "$production_checker" >"$checker_destination"
    chmod +x "$checker_destination"
    printf 'synthetic bounded-checker contract repository\n' \
        >"$current_repository/README.md"
    for (( index = 1; index <= preboundary_path_count; index++ )); do
        printf 'pre-boundary fixture %s\n' "$index" \
            >"$current_repository/Sources/PreBoundary-$index.txt"
    done
    git -C "$current_repository" add -A
    git -C "$current_repository" commit -qm "install bounded checker harness"

    mkdir -p "$current_repository/${plan_path%/*}"
    printf '# Synthetic historical-ledger plan boundary\n' \
        >"$current_repository/$plan_path"
    git -C "$current_repository" add "$plan_path"
    git -C "$current_repository" commit -qm "add synthetic plan boundary"
}

commit_all() {
    local repository=$1
    local message=$2

    git -C "$repository" add -A
    git -C "$repository" commit -qm "$message"
}

run_checker() {
    local repository=$1

    (
        cd "$repository"
        ./Scripts/check-historical-ledger-privacy.sh
    )
}

create_git_shim() {
    local label=$1

    current_shim_directory="$temporary_root/shims/$label"
    mkdir -p "$current_shim_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$*" == *"$SPACETRACE_TEST_GIT_FAIL_MATCH"* ]]; then' \
        '    exit 73' \
        'fi' \
        'exec "$SPACETRACE_TEST_REAL_GIT" "$@"' \
        >"$current_shim_directory/git"
    chmod +x "$current_shim_directory/git"
}

run_checker_with_git_failure() {
    local repository=$1
    local failing_arguments=$2
    local shim_directory=$3

    (
        cd "$repository"
        PATH="$shim_directory:$PATH" \
        SPACETRACE_TEST_REAL_GIT="$real_git" \
        SPACETRACE_TEST_GIT_FAIL_MATCH="$failing_arguments" \
            ./Scripts/check-historical-ledger-privacy.sh
    )
}

create_rg_failure_shim() {
    local label=$1

    current_shim_directory="$temporary_root/shims/$label"
    mkdir -p "$current_shim_directory"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 2' \
        >"$current_shim_directory/rg"
    chmod +x "$current_shim_directory/rg"
}

run_checker_with_rg_failure() {
    local repository=$1
    local shim_directory=$2

    (
        cd "$repository"
        PATH="$shim_directory:$PATH" \
            ./Scripts/check-historical-ledger-privacy.sh
    )
}

create_swiftc_failure_shim() {
    local label=$1

    current_shim_directory="$temporary_root/shims/$label"
    mkdir -p "$current_shim_directory"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 73' \
        >"$current_shim_directory/swiftc"
    chmod +x "$current_shim_directory/swiftc"
}

create_swiftc_structure_shim() {
    local label=$1

    current_shim_directory="$temporary_root/shims/$label"
    mkdir -p "$current_shim_directory"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'case "$SPACETRACE_TEST_AST_SHAPE" in' \
        '    missing-global)' \
        '        printf '\''%s\n'\'' '\''(source_file "<stdin>"'\'' '\''  (pattern_named type="<null>" "spacetraceParserProbe")'\'' '\''  (unresolved_dot_expr type="<null>" field="info" function_ref=unapplied))'\''' \
        '        ;;' \
        '    missing-member)' \
        '        printf '\''%s\n'\'' '\''(source_file "<stdin>"'\'' '\''  (pattern_named type="<null>" "spacetraceParserProbe")'\'' '\''  (unresolved_decl_ref_expr type="<null>" name="print" function_ref=unapplied))'\''' \
        '        ;;' \
        '    missing-qualified)' \
        '        printf '\''%s\n'\'' '\''(source_file "<stdin>"'\'' '\''  (pattern_named type="<null>" "spacetraceParserProbe")'\'' '\''  (unresolved_decl_ref_expr type="<null>" name="Logger" function_ref=unapplied)'\'' '\''  (unresolved_dot_expr type="<null>" field="info" function_ref=unapplied))'\''' \
        '        ;;' \
        '    *) exit 73 ;;' \
        'esac' \
        >"$current_shim_directory/swiftc"
    chmod +x "$current_shim_directory/swiftc"
}

run_checker_with_swiftc_failure() {
    local repository=$1
    local shim_directory=$2

    (
        cd "$repository"
        PATH="$shim_directory:$PATH" \
            ./Scripts/check-historical-ledger-privacy.sh
    )
}

run_checker_with_swiftc_structure() {
    local repository=$1
    local shim_directory=$2
    local ast_shape=$3

    (
        cd "$repository"
        PATH="$shim_directory:$PATH" \
        SPACETRACE_TEST_AST_SHAPE="$ast_shape" \
            ./Scripts/check-historical-ledger-privacy.sh
    )
}

run_checker_with_base_override() {
    local repository=$1

    (
        cd "$repository"
        SPACETRACE_HISTORICAL_LEDGER_PRIVACY_BASE=HEAD \
            ./Scripts/check-historical-ledger-privacy.sh
    )
}

expect_acceptance() {
    local label=$1
    local repository=$2
    local base=$3
    local output

    if ! output=$(run_checker "$repository" "$base" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "safe input was rejected"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_rejection() {
    local label=$1
    local repository=$2
    local base=$3
    local expected_path=$4
    local expected_category=${5:-}
    local output
    local status

    if output=$(run_checker "$repository" "$base" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "forbidden input was accepted"
        return
    else
        status=$?
    fi
    if (( status != 1 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "privacy violation exited $status instead of 1"
        return
    fi
    case "$output" in
        *"historical ledger privacy gate: violation:"*) ;;
        *)
            printf '%s\n' "$output" >&2
            record_contract_failure "$label" \
                "diagnostic omitted the stable violation category"
            return
            ;;
    esac
    if [[ -n "$expected_category" && \
          "$output" != *"historical ledger privacy gate: violation: $expected_category"* ]]; then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "diagnostic did not report the expected violation category"
        return
    fi
    if [[ "$output" == *"$expected_path"* ]]; then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "diagnostic exposed a repository path"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_base_override_failure_closed() {
    local label=$1
    local repository=$2
    local output
    local status

    if output=$(run_checker_with_base_override "$repository" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "base override disabled cumulative scanning"
        return
    else
        status=$?
    fi
    if (( status != 2 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "base override rejection exited $status instead of 2"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_git_producer_failure_closed() {
    local label=$1
    local repository=$2
    local base=$3
    local failing_arguments=$4
    local output
    local status

    create_git_shim "$label"
    if output=$(run_checker_with_git_failure "$repository" \
        "$failing_arguments" "$current_shim_directory" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "git producer failure was ignored"
        return
    else
        status=$?
    fi
    if (( status != 2 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "git producer failure exited $status instead of 2"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_rg_failure_closed() {
    local label=$1
    local repository=$2
    local base=$3
    local output
    local status

    create_rg_failure_shim "$label"
    if output=$(run_checker_with_rg_failure "$repository" \
        "$current_shim_directory" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "rg exit 2 was treated as no match"
        return
    else
        status=$?
    fi
    if (( status != 2 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "rg failure exited $status instead of 2"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_swiftc_failure_closed() {
    local label=$1
    local repository=$2
    local output
    local status

    create_swiftc_failure_shim "$label"
    if output=$(run_checker_with_swiftc_failure "$repository" \
        "$current_shim_directory" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "swiftc failure was ignored"
        return
    else
        status=$?
    fi
    if (( status != 2 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "swiftc failure exited $status instead of 2"
        return
    fi
    if [[ "$output" != *"historical ledger privacy gate: infrastructure failure"* ]]; then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "swiftc failure omitted its stable infrastructure diagnostic"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_swiftc_structure_failure_closed() {
    local label=$1
    local repository=$2
    local ast_shape=$3
    local output
    local status

    create_swiftc_structure_shim "$label"
    if output=$(run_checker_with_swiftc_structure "$repository" \
        "$current_shim_directory" "$ast_shape" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "swiftc AST contract drift was ignored"
        return
    else
        status=$?
    fi
    if (( status != 2 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "swiftc AST contract drift exited $status instead of 2"
        return
    fi
    if [[ "$output" != *"historical ledger privacy gate: infrastructure failure"* ]]; then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "swiftc AST contract drift omitted its stable infrastructure diagnostic"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_infrastructure_failure() {
    local label=$1
    local repository=$2
    local expected_diagnostic=$3
    local output
    local status

    if output=$(run_checker "$repository" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "incomplete scan was accepted"
        return
    else
        status=$?
    fi
    if (( status != 2 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "infrastructure failure exited $status instead of 2"
        return
    fi
    if [[ "$output" != *"$expected_diagnostic"* ]]; then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "infrastructure failure omitted its stable diagnostic"
        return
    fi
    passed_cases=$((passed_cases + 1))
}

expect_sanitized_path_rejection() {
    local label=$1
    local repository=$2
    local sensitive_path=$3
    local sensitive_name=${sensitive_path##*/}
    local sensitive_token=${sensitive_name%.*}
    local output
    local status

    if output=$(run_checker "$repository" 2>&1); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "token-shaped path was accepted"
        return
    else
        status=$?
    fi
    if (( status != 1 )); then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" \
            "privacy violation exited $status instead of 1"
        return
    fi
    if [[ "$output" == *"$sensitive_path"* || \
          "$output" == *"$sensitive_name"* || \
          "$output" == *"$sensitive_token"* ]]; then
        printf '%s\n' "$output" >&2
        record_contract_failure "$label" "diagnostic repeated the sensitive path"
        return
    fi
    case "$output" in
        *"historical ledger privacy gate: violation:"*) ;;
        *)
            printf '%s\n' "$output" >&2
            record_contract_failure "$label" \
                "diagnostic omitted the stable violation category"
            return
            ;;
    esac
    passed_cases=$((passed_cases + 1))
}

write_secret_probe() {
    local destination=$1
    local token_prefix="g""hp_"

    printf 'token=%s%s\nsynthetic-contract-probe-only\n' "$token_prefix" \
        "0123456789abcdefghijklmnopqrstuvwxyz" >"$destination"
}

write_private_key_probe() {
    local destination=$1
    local key_header="-----BEGIN OPEN""SSH PRIVATE KEY-----"

    {
        printf '%s\n' "$key_header"
        printf 'synthetic-contract-probe-only\n'
    } >"$destination"
}

write_secret_kind_probe() {
    local destination=$1
    local kind=$2
    local marker

    case "$kind" in
        github-classic)
            marker="g""hp_0123456789abcdefghijklmnopqrstuvwxyz"
            ;;
        github-fine-grained)
            marker="github""_pat_0123456789abcdefghijklmnopqrstuv"
            ;;
        aws-access-key)
            marker="A""KIA0123456789ABCDEF"
            ;;
        aws-session-key)
            marker="A""SIA0123456789ABCDEF"
            ;;
        github-oauth)
            marker="gh""o_0123456789abcdefghijklmnopqrstuv"
            ;;
        github-user)
            marker="gh""u_0123456789abcdefghijklmnopqrstuv"
            ;;
        github-server)
            marker="gh""s_0123456789abcdefghijklmnopqrstuv"
            ;;
        github-refresh)
            marker="gh""r_0123456789abcdefghijklmnopqrstuv"
            ;;
        rsa-private-key)
            marker="-----BEGIN R""SA PRIVATE KEY-----"
            ;;
        ec-private-key)
            marker="-----BEGIN E""C PRIVATE KEY-----"
            ;;
        dsa-private-key)
            marker="-----BEGIN D""SA PRIVATE KEY-----"
            ;;
        pkcs8-private-key)
            marker="-----BEGIN PRI""VATE KEY-----"
            ;;
        *) fail "unsupported secret probe: $kind" ;;
    esac

    printf '%s\nsynthetic-contract-probe-only\n' "$marker" >"$destination"
}

write_real_home_probe() {
    local destination=$1
    local user_name
    local probe_value

    user_name=$(id -un)
    probe_value=$(printf '/%s/%s/Documents/SpaceTrace-private-ledger.sqlite' \
        "Users" "$user_name")
    printf 'let persistedLocation = "%s"\n' "$probe_value" >"$destination"
}

write_bare_real_home_probe() {
    local destination=$1
    local user_name
    local probe_value

    user_name=$(id -un)
    probe_value=$(printf '/%s/%s' "Users" "$user_name")
    printf 'let persistedLocation = "%s"\n' "$probe_value" >"$destination"
}

write_sink_probe() {
    local destination=$1
    local sink=$2
    local sensitive_name=$3

    local method_name="in""fo"

    case "$sink" in
        logger|log)
            printf '%s.%s("candidate: \\(%s)")\n' \
                "$sink" "$method_name" "$sensitive_name" \
                >"$destination"
            ;;
        print|dump)
            printf '%s(%s)\n' "$sink" "$sensitive_name" >"$destination"
            ;;
        *) fail "unsupported sink probe" ;;
    esac
}

write_multiline_logger_probe() {
    local destination=$1
    local sink_name="log""ger"
    local sensitive_name="raw""Path"
    local method_name="in""fo"

    printf '%s.%s(\n    "candidate: \\(%s)"\n)\n' \
        "$sink_name" "$method_name" "$sensitive_name" >"$destination"
}

write_long_logger_probe() {
    local destination=$1
    local sink_name="lo""g"
    local method_name="in""fo"
    local sensitive_name="raw""Path"

    printf '%s.%s(\n    "' "$sink_name" "$method_name" >"$destination"
    printf '%04200d' 0 >>"$destination"
    printf 'candidate: \\(%s)"\n)\n' "$sensitive_name" >>"$destination"
}

write_logger_constructor_probe() {
    local destination=$1
    local type_name="Log""ger"
    local method_name="in""fo"

    printf '%s().%s("direct sink")\n' "$type_name" "$method_name" \
        >"$destination"
}

write_optional_logger_probe() {
    local destination=$1
    local receiver="log""ger"
    local method_name="er""ror"

    printf '%s?.%s("direct sink")\n' "$receiver" "$method_name" \
        >"$destination"
}

write_function_alias_probe() {
    local destination=$1
    local sink_name="pri""nt"

    printf 'let emit = %s\nemit("direct sink")\n' "$sink_name" >"$destination"
}

write_swift_syntax_sink_probe() {
    local destination=$1
    local shape=$2
    local receiver="log""ger"
    local method_name="in""fo"
    local console_sink="pri""nt"
    local sensitive_name="raw""Path"

    case "$shape" in
        commented-global)
            printf '%s/* lexical trivia */(%s)\n' \
                "$console_sink" "$sensitive_name" >"$destination"
            ;;
        commented-member)
            printf '%s/* lexical trivia */.%s/* lexical trivia */(%s)\n' \
                "$receiver" "$method_name" "$sensitive_name" >"$destination"
            ;;
        parenthesized-receiver)
            printf '(%s).%s(%s)\n' \
                "$receiver" "$method_name" "$sensitive_name" >"$destination"
            ;;
        subscript-receiver)
            printf '[%s][0].%s(%s)\n' \
                "$receiver" "$method_name" "$sensitive_name" >"$destination"
            ;;
        escaped-global)
            printf '\140%s\140(%s)\n' \
                "$console_sink" "$sensitive_name" >"$destination"
            ;;
        qualified-logger)
            printf 'OSLog.Logger().%s(%s)\n' \
                "$method_name" "$sensitive_name" >"$destination"
            ;;
        qualified-posix-write)
            printf 'Darwin.write(STDERR_FILENO, %s, %s.count)\n' \
                "$sensitive_name" "$sensitive_name" >"$destination"
            ;;
        qualified-foundation-log)
            printf 'Foundation.NSLogv("%%s", getVaList([%s]))\n' \
                "$sensitive_name" >"$destination"
            ;;
        qualified-os-log)
            printf 'OSLog.os_log_with_type(log, .error, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        *) fail "unsupported Swift syntax sink probe" ;;
    esac
}

write_named_diagnostic_sink_probe() {
    local destination=$1
    local sink_name=$2
    local sensitive_name="raw""Path"

    case "$sink_name" in
        fatalError|preconditionFailure|assertionFailure|puts|perror)
            printf '%s(%s)\n' "$sink_name" "$sensitive_name" >"$destination"
            ;;
        assert|precondition)
            printf '%s(false, %s)\n' \
                "$sink_name" "$sensitive_name" >"$destination"
            ;;
        printf)
            printf 'printf("%%s", %s)\n' "$sensitive_name" >"$destination"
            ;;
        vprintf)
            printf 'vprintf("%%s", %sArguments)\n' \
                "$sensitive_name" >"$destination"
            ;;
        fputs)
            printf 'fputs(%s, stderr)\n' "$sensitive_name" >"$destination"
            ;;
        fprintf)
            printf 'fprintf(stderr, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        syslog)
            printf 'syslog(0, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        vsyslog)
            printf 'vsyslog(0, "%%s", %sArguments)\n' \
                "$sensitive_name" >"$destination"
            ;;
        write)
            printf 'write(STDERR_FILENO, %s, %s.count)\n' \
                "$sensitive_name" "$sensitive_name" >"$destination"
            ;;
        writev)
            printf 'writev(STDERR_FILENO, %sVectors, 1)\n' \
                "$sensitive_name" >"$destination"
            ;;
        dprintf)
            printf 'dprintf(STDERR_FILENO, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        vdprintf)
            printf 'vdprintf(STDERR_FILENO, "%%s", %sArguments)\n' \
                "$sensitive_name" >"$destination"
            ;;
        vfprintf)
            printf 'vfprintf(stderr, "%%s", %sArguments)\n' \
                "$sensitive_name" >"$destination"
            ;;
        fwrite)
            printf 'fwrite(%s, 1, %s.count, stderr)\n' \
                "$sensitive_name" "$sensitive_name" >"$destination"
            ;;
        CFShow)
            printf 'CFShow(%s)\n' "$sensitive_name" >"$destination"
            ;;
        NSLogv)
            printf 'NSLogv("%%s", getVaList([%s]))\n' \
                "$sensitive_name" >"$destination"
            ;;
        os-logv)
            printf 'os_logv("%%s", %sArguments)\n' \
                "$sensitive_name" >"$destination"
            ;;
        os-log-error)
            printf 'os_log_error(log, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        os-log-with-type)
            printf 'os_log_with_type(log, .error, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        os-signpost)
            printf 'os_signpost(.event, log: log, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        os-signpost-event)
            printf 'os_signpost_event_emit(log, id, "%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        standard-error)
            printf 'FileHandle.standardError.write(data)\n' >"$destination"
            ;;
        standard-output)
            printf 'FileHandle.standardOutput.write(data)\n' >"$destination"
            ;;
        signposter-constructor)
            printf 'OSSignposter().emitEvent("%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        signposter-member)
            printf 'signposter.emitEvent("%%s", %s)\n' \
                "$sensitive_name" >"$destination"
            ;;
        exception-raise)
            printf 'exception.raise()\n' >"$destination"
            ;;
        *) fail "unsupported named diagnostic sink probe" ;;
    esac
}

write_safe_swift_diagnostic_text_probe() {
    local destination=$1
    local receiver="log""ger"
    local method_name="in""fo"
    local console_sink="pri""nt"

    printf '// %s.%s(rawPath) is documentation, not a call.\n' \
        "$receiver" "$method_name" >"$destination"
    printf '/* %s(rawPath) is inert review text. */\n' \
        "$console_sink" >>"$destination"
    printf 'let example = "%s.%s(rawPath)"\n' \
        "$receiver" "$method_name" >>"$destination"
}

write_safe_member_write_probe() {
    local destination=$1

    printf 'try data.write(to: destinationURL)\n' >"$destination"
}

write_imported_closure_annotation_probe() {
    local destination=$1

    printf '%s\n' \
        'import Foundation' \
        'struct ClockBox {' \
        '    let now: @Sendable () -> Date' \
        '    init(now: @escaping @Sendable () -> Date) {' \
        '        self.now = now' \
        '    }' \
        '}' >"$destination"
}

write_malformed_swift_probe() {
    local destination=$1

    printf '%s\n' 'func unfinished(' >"$destination"
}

write_released_fixture_manifest() {
    local manifest_path=$1
    local schema_version=$2
    local relative_path=$3
    local digest=$4

    printf '{\n  "formatVersion": 1,\n  "fixtures": [\n    {\n      "schemaVersion": %s,\n      "relativePath": "%s",\n      "sha256": "%s"\n    }\n  ]\n}\n' \
        "$schema_version" "$relative_path" "$digest" >"$manifest_path"
}

write_v2_released_fixture_manifest() {
    local manifest_path=$1
    local schema_version=$2
    local relative_path=$3
    local digest=$4
    local generator_path=$5
    local generator_version=$6
    local seed=$7
    local semantic_digest=$8
    local schema_object_digest=$9

    printf '{\n  "formatVersion": 2,\n  "fixtures": [\n    {\n      "schemaVersion": %s,\n      "relativePath": "%s",\n      "sha256": "%s",\n      "generatorPath": "%s",\n      "generatorVersion": "%s",\n      "seed": "%s",\n      "semanticSHA256": "%s",\n      "schemaObjectSHA256": "%s"\n    }\n  ]\n}\n' \
        "$schema_version" "$relative_path" "$digest" "$generator_path" \
        "$generator_version" "$seed" "$semantic_digest" \
        "$schema_object_digest" >"$manifest_path"
}

# A secret introduced and then deleted after the plan boundary must remain in
# scope. Looking only at HEAD, the final tree, or the current diff misses it.
create_repository "cumulative-committed"
cumulative_repository=$current_repository
cumulative_base=$current_base
write_secret_probe "$cumulative_repository/Sources/CommittedLeak.swift"
commit_all "$cumulative_repository" "introduce historical probe"
rm "$cumulative_repository/Sources/CommittedLeak.swift"
printf 'let currentState = "safe"\n' \
    >"$cumulative_repository/Sources/CurrentState.swift"
commit_all "$cumulative_repository" "remove historical probe from head"
expect_rejection "cumulative committed history" "$cumulative_repository" \
    "$cumulative_base" "Sources/CommittedLeak.swift"

# A merge conflict resolution can introduce bytes that exist in neither parent.
# The later deletion makes the merge tree itself the only remaining evidence.
create_repository "merge-resolution"
merge_repository=$current_repository
merge_base=$current_base
primary_branch=$(git -C "$merge_repository" symbolic-ref --short HEAD)
printf 'let branchValue = "base"\n' \
    >"$merge_repository/Sources/MergeResolution.swift"
commit_all "$merge_repository" "add merge conflict base"
git -C "$merge_repository" checkout -qb privacy-side
printf 'let branchValue = "side"\n' \
    >"$merge_repository/Sources/MergeResolution.swift"
commit_all "$merge_repository" "change synthetic side"
git -C "$merge_repository" checkout -q "$primary_branch"
printf 'let branchValue = "primary"\n' \
    >"$merge_repository/Sources/MergeResolution.swift"
commit_all "$merge_repository" "change synthetic primary"
if git -C "$merge_repository" merge --no-ff privacy-side \
    -m "merge synthetic side" >/dev/null 2>&1; then
    fail "merge-resolution probe did not create the expected conflict"
fi
write_secret_probe "$merge_repository/Sources/MergeResolution.swift"
git -C "$merge_repository" add Sources/MergeResolution.swift
git -C "$merge_repository" commit -qm "resolve conflict with historical probe"
printf 'let branchValue = "safe-after-merge"\n' \
    >"$merge_repository/Sources/MergeResolution.swift"
commit_all "$merge_repository" "remove merge-only historical probe"
expect_rejection "merge-only conflict-resolution history" "$merge_repository" \
    "$merge_base" "Sources/MergeResolution.swift"

# Every fixture exercises the default plan-add discovery. This dedicated case
# proves that a leak after that boundary is still found after later deletion.
create_repository "default-plan-bootstrap"
bootstrap_repository=$current_repository
write_secret_probe "$bootstrap_repository/Sources/DefaultBaseLeak.swift"
commit_all "$bootstrap_repository" "introduce default-base probe"
rm "$bootstrap_repository/Sources/DefaultBaseLeak.swift"
commit_all "$bootstrap_repository" "remove default-base probe"
expect_rejection "default plan-base bootstrap" "$bootstrap_repository" "" \
    "Sources/DefaultBaseLeak.swift"

# No environment or CLI input may move the durable cumulative-history boundary.
create_repository "base-override"
base_override_repository=$current_repository
expect_base_override_failure_closed "base override is rejected" \
    "$base_override_repository"

# Local replacement refs can rewrite rev-list/diff-tree object resolution and
# must be rejected before the checker trusts any cumulative-history result.
create_repository "git-replace"
replace_repository=$current_repository
write_secret_probe "$replace_repository/Sources/ReplacedHistory.swift"
commit_all "$replace_repository" "introduce replace-hidden history"
replaced_commit=$(git -C "$replace_repository" rev-parse HEAD)
rm "$replace_repository/Sources/ReplacedHistory.swift"
commit_all "$replace_repository" "remove replace-hidden history"
git -C "$replace_repository" replace "$replaced_commit" "${replaced_commit}^"
expect_rejection "Git replacement refs" "$replace_repository" "" \
    "Sources/ReplacedHistory.swift" \
    "Git replacement refs can hide cumulative history"

create_repository "git-graft"
graft_repository=$current_repository
graft_head=$(git -C "$graft_repository" rev-parse HEAD)
graft_parent=$(git -C "$graft_repository" rev-parse HEAD^)
printf '%s %s\n' "$graft_head" "$graft_parent" \
    >"$graft_repository/.git/info/grafts"
expect_rejection "Git grafts" "$graft_repository" "" \
    ".git/info/grafts" "Git grafts can hide cumulative history"

create_repository "shallow-source"
shallow_source_repository=$current_repository
printf 'safe shallow-clone tip\n' \
    >"$shallow_source_repository/Sources/ShallowTip.txt"
commit_all "$shallow_source_repository" "add shallow clone tip"
shallow_repository="$temporary_root/shallow-clone"
git clone -q --depth=1 "file://$shallow_source_repository" \
    "$shallow_repository"
expect_infrastructure_failure "shallow repository" "$shallow_repository" \
    "historical ledger privacy gate: complete Git history is required"

# The worktree union includes every Git surface, not only committed history.
create_repository "staged"
staged_repository=$current_repository
staged_base=$current_base
write_secret_probe "$staged_repository/Sources/StagedLeak.swift"
git -C "$staged_repository" add Sources/StagedLeak.swift
expect_rejection "staged file" "$staged_repository" "$staged_base" \
    "Sources/StagedLeak.swift"

create_repository "unstaged"
unstaged_repository=$current_repository
unstaged_base=$current_base
printf 'let state = "safe"\n' >"$unstaged_repository/Sources/Tracked.swift"
commit_all "$unstaged_repository" "add safe tracked source"
write_secret_probe "$unstaged_repository/Sources/Tracked.swift"
expect_rejection "unstaged file" "$unstaged_repository" "$unstaged_base" \
    "Sources/Tracked.swift"

create_repository "untracked"
untracked_repository=$current_repository
untracked_base=$current_base
write_secret_probe "$untracked_repository/Sources/UntrackedLeak.swift"
expect_rejection "untracked file" "$untracked_repository" "$untracked_base" \
    "Sources/UntrackedLeak.swift"

# The per-artifact bound is checked from stat/object metadata before bytes are
# copied into the checker temporary directory.
create_repository "oversized-artifact"
oversized_repository=$current_repository
truncate -s 33554433 "$oversized_repository/Sources/OversizedFixture.bin"
expect_rejection "oversized artifact preflight" "$oversized_repository" "" \
    "Sources/OversizedFixture.bin" \
    "changed artifact exceeds the per-file scan bound"

# Production limits are immutable and large. These fixtures install the exact
# checker with only its constants reduced before the trusted plan boundary, so
# every resource branch can be exercised without a production override.
create_bounded_repository "commit-count-bound" 2 20000 536870912 \
    20000 67108864 0
commit_bound_repository=$current_repository
git -C "$commit_bound_repository" commit --allow-empty -qm \
    "first bounded commit"
git -C "$commit_bound_repository" commit --allow-empty -qm \
    "second bounded commit"
expect_rejection "commit count bound" "$commit_bound_repository" "" \
    "docs/superpowers/plans/2026-08-11-sqlite-v11-historical-ledger.md" \
    "commit count exceeds the cumulative scan bound"

create_bounded_repository "artifact-count-bound" 4096 2 536870912 \
    20000 67108864 0
artifact_bound_repository=$current_repository
printf 'first bounded artifact\n' \
    >"$artifact_bound_repository/Sources/Artifact-A.txt"
printf 'second bounded artifact\n' \
    >"$artifact_bound_repository/Sources/Artifact-B.txt"
commit_all "$artifact_bound_repository" "add bounded artifact pair"
expect_rejection "artifact count bound" "$artifact_bound_repository" "" \
    "Sources/Artifact-B.txt" \
    "changed artifact count exceeds the cumulative scan bound"

create_bounded_repository "cumulative-byte-bound" 4096 20000 200 \
    20000 67108864 0
byte_bound_repository=$current_repository
printf '%0100d' 0 >"$byte_bound_repository/Sources/Bytes-A.txt"
printf '%0100d' 1 >"$byte_bound_repository/Sources/Bytes-B.txt"
commit_all "$byte_bound_repository" "add cumulative byte fixtures"
expect_rejection "cumulative materialized byte bound" \
    "$byte_bound_repository" "" "Sources/Bytes-B.txt" \
    "changed artifacts exceed the cumulative byte bound"

create_bounded_repository "deletion-path-count-bound" 4096 20000 \
    536870912 6 67108864 4
deletion_bound_repository=$current_repository
rm "$deletion_bound_repository"/Sources/PreBoundary-*.txt
commit_all "$deletion_bound_repository" "delete pre-boundary path set"
expect_rejection "deletion-only path count bound" \
    "$deletion_bound_repository" "" "Sources/PreBoundary-4.txt" \
    "enumerated repository path count exceeds its cumulative bound"

create_bounded_repository "path-byte-bound" 4096 20000 536870912 \
    20000 400 0
path_byte_repository=$current_repository
long_component=$(printf '%0210d' 0)
long_relative_path="Sources/${long_component}.txt"
printf 'safe long-path fixture\n' \
    >"$path_byte_repository/$long_relative_path"
expect_rejection "enumerated path byte bound" "$path_byte_repository" "" \
    "$long_relative_path" \
    "enumerated repository path bytes exceed their cumulative bound"

# Empty directories under the released-fixture root are invisible to Git and do
# not match the fixture filename filter. They must still consume the worktree
# enumeration budget before find traverses an unbounded tree.
create_bounded_repository "fixture-empty-directory-bound" 4096 20000 \
    536870912 8 67108864 0
fixture_directory_bound_repository=$current_repository
fixture_directory_bound_root="$fixture_directory_bound_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
for directory_index in 1 2 3 4 5 6; do
    mkdir -p "$fixture_directory_bound_root/ignored-$directory_index"
done
expect_rejection "released fixture nonmatching entry count bound" \
    "$fixture_directory_bound_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/ignored-6" \
    "enumerated repository path count exceeds its cumulative bound"

create_bounded_repository "swift-source-byte-bound" 4096 20000 536870912 \
    20000 67108864 0 32 67108864
swift_source_bound_repository=$current_repository
printf '// %0100d\n' 0 \
    >"$swift_source_bound_repository/Sources/BoundedSource.swift"
expect_rejection "Swift parser input byte bound" \
    "$swift_source_bound_repository" "" "Sources/BoundedSource.swift" \
    "Swift source exceeds its parser input bound"

create_bounded_repository "swift-parse-byte-bound" 4096 20000 536870912 \
    20000 67108864 0 2097152 4096
swift_parse_bound_repository=$current_repository
: >"$swift_parse_bound_repository/Sources/BoundedParse.swift"
for parse_index in {1..64}; do
    printf 'let boundedSyntaxTree%s = %s\n' "$parse_index" "$parse_index" \
        >>"$swift_parse_bound_repository/Sources/BoundedParse.swift"
done
expect_rejection "Swift parser output byte bound" \
    "$swift_parse_bound_repository" "" "Sources/BoundedParse.swift" \
    "Swift parse evidence exceeds its scan bound"

# Repository paths are also untrusted. A secret-shaped filename must be rejected
# without echoing the original path or token into stderr.
create_repository "token-shaped-filename"
token_path_repository=$current_repository
token_prefix="github""_pat_"
token_name="${token_prefix}0123456789abcdefghijklmnopqrstuv.swift"
token_relative_path="Sources/$token_name"
printf 'let fixtureState = "safe"\n' \
    >"$token_path_repository/$token_relative_path"
expect_sanitized_path_rejection "token-shaped sensitive filename" \
    "$token_path_repository" "$token_relative_path"

# Git index visibility flags can hide local bytes from ordinary diff/status
# producers. Their presence is an explicit privacy violation with exit 1.
create_repository "assume-unchanged"
assume_repository=$current_repository
printf 'let hiddenState = "safe"\n' \
    >"$assume_repository/Sources/AssumeHidden.swift"
commit_all "$assume_repository" "add assume-unchanged probe"
git -C "$assume_repository" update-index --assume-unchanged \
    Sources/AssumeHidden.swift
write_secret_probe "$assume_repository/Sources/AssumeHidden.swift"
expect_rejection "assume-unchanged index entry" "$assume_repository" "" \
    "Sources/AssumeHidden.swift"

create_repository "skip-worktree"
skip_repository=$current_repository
printf 'let hiddenState = "safe"\n' \
    >"$skip_repository/Sources/SkipHidden.swift"
commit_all "$skip_repository" "add skip-worktree probe"
git -C "$skip_repository" update-index --skip-worktree Sources/SkipHidden.swift
write_secret_probe "$skip_repository/Sources/SkipHidden.swift"
expect_rejection "skip-worktree index entry" "$skip_repository" "" \
    "Sources/SkipHidden.swift"

# A producer error is an incomplete scan, never an empty successful input set.
create_repository "rev-list-failure"
rev_list_repository=$current_repository
rev_list_base=$current_base
expect_git_producer_failure_closed "rev-list-producer" \
    "$rev_list_repository" "$rev_list_base" "rev-list --max-count"

create_repository "cached-diff-failure"
cached_diff_repository=$current_repository
cached_diff_base=$current_base
printf 'let stagedState = "safe"\n' \
    >"$cached_diff_repository/Sources/StagedSafe.swift"
git -C "$cached_diff_repository" add Sources/StagedSafe.swift
expect_git_producer_failure_closed "cached-diff-producer" \
    "$cached_diff_repository" "$cached_diff_base" \
    "diff --cached --name-only"

create_repository "cat-file-failure"
cat_file_repository=$current_repository
cat_file_base=$current_base
printf 'let committedState = "safe"\n' \
    >"$cat_file_repository/Sources/CatFileSafe.swift"
commit_all "$cat_file_repository" "add cat-file producer probe"
expect_git_producer_failure_closed "cat-file-producer" \
    "$cat_file_repository" "$cat_file_base" "cat-file -s"

# ripgrep distinguishes no-match (1) from execution/parse failure (2+).
create_repository "rg-exit-two"
rg_failure_repository=$current_repository
rg_failure_base=$current_base
write_secret_probe "$rg_failure_repository/Sources/RGFailureLeak.swift"
expect_rg_failure_closed "rg-exit-two" "$rg_failure_repository" \
    "$rg_failure_base"

# The compiler parser is a trusted producer too. A toolchain crash/failure is
# incomplete evidence (exit 2), not a source privacy finding (exit 1).
create_repository "swiftc-exit-seventy-three"
swiftc_failure_repository=$current_repository
expect_swiftc_failure_closed "swiftc-exit-seventy-three" \
    "$swiftc_failure_repository"

# A successful compiler process is still unusable evidence when its AST output
# no longer carries either node shape consumed by the production matcher.
for ast_shape in missing-global missing-member missing-qualified; do
    create_repository "swiftc-ast-$ast_shape"
    swiftc_structure_repository=$current_repository
    expect_swiftc_structure_failure_closed "swiftc-ast-$ast_shape" \
        "$swiftc_structure_repository" "$ast_shape"
done

# A private-key marker must be rejected independently of token-pattern matches.
create_repository "private-key-only"
private_key_repository=$current_repository
private_key_base=$current_base
write_private_key_probe "$private_key_repository/Sources/PrivateKeyLeak.txt"
expect_rejection "private-key marker" "$private_key_repository" \
    "$private_key_base" "Sources/PrivateKeyLeak.txt"

# Each supported credential/key family is independently observable. Combining
# markers in one fixture could let one regex hide a missing detector for another.
for secret_kind in \
    github-classic \
    github-fine-grained \
    github-oauth \
    github-user \
    github-server \
    github-refresh \
    aws-access-key \
    aws-session-key \
    rsa-private-key \
    ec-private-key \
    dsa-private-key \
    pkcs8-private-key; do
    create_repository "secret-$secret_kind"
    secret_repository=$current_repository
    secret_base=$current_base
    secret_path="Sources/Secret-$secret_kind.txt"
    write_secret_kind_probe "$secret_repository/$secret_path" "$secret_kind"
    expect_rejection "independent $secret_kind detector" "$secret_repository" \
        "$secret_base" "$secret_path"
done

# The checker itself remains in the cumulative file set and must not trigger
# its own detection patterns.
create_repository "checker-self-scan"
self_scan_repository=$current_repository
self_scan_base=$current_base
cp "$production_checker" "$self_scan_repository/Sources/CheckerCopy.sh"
expect_acceptance "checker source self-scan" "$self_scan_repository" \
    "$self_scan_base"

# A host-derived macOS home path is sensitive even when it is not a credential.
create_repository "real-home"
home_repository=$current_repository
home_base=$current_base
write_real_home_probe "$home_repository/Sources/RealHomeLeak.swift"
expect_rejection "real user home path" "$home_repository" "$home_base" \
    "Sources/RealHomeLeak.swift"

create_repository "bare-real-home"
bare_home_repository=$current_repository
bare_home_base=$current_base
write_bare_real_home_probe "$bare_home_repository/Sources/BareRealHomeLeak.swift"
expect_rejection "bare real user home path" "$bare_home_repository" \
    "$bare_home_base" "Sources/BareRealHomeLeak.swift"

# Path-bearing values must not be sent to common Swift diagnostics sinks.
sink_logger="logger"
sink_print="print"
sink_dump="dump"
path_value_name="rawPath"
display_value_name="displayName"

create_repository "logger-sink"
logger_repository=$current_repository
logger_base=$current_base
write_sink_probe "$logger_repository/Sources/LoggerLeak.swift" \
    "$sink_logger" "$path_value_name"
expect_rejection "logger path sink" "$logger_repository" "$logger_base" \
    "Sources/LoggerLeak.swift"

create_repository "multiline-logger-sink"
multiline_logger_repository=$current_repository
multiline_logger_base=$current_base
write_multiline_logger_probe \
    "$multiline_logger_repository/Sources/MultilineLoggerLeak.swift"
expect_rejection "multiline logger path sink" \
    "$multiline_logger_repository" "$multiline_logger_base" \
    "Sources/MultilineLoggerLeak.swift"

create_repository "log-alias-sink"
log_alias_repository=$current_repository
log_alias_base=$current_base
write_sink_probe "$log_alias_repository/Sources/LogAliasLeak.swift" \
    "log" "$path_value_name"
expect_rejection "log alias path sink" "$log_alias_repository" \
    "$log_alias_base" "Sources/LogAliasLeak.swift"

create_repository "unbounded-logger-sink"
long_logger_repository=$current_repository
long_logger_base=$current_base
write_long_logger_probe \
    "$long_logger_repository/Sources/LongLoggerLeak.swift"
expect_rejection "logger sink beyond the old byte window" \
    "$long_logger_repository" "$long_logger_base" \
    "Sources/LongLoggerLeak.swift"

create_repository "logger-constructor-sink"
logger_constructor_repository=$current_repository
logger_constructor_base=$current_base
write_logger_constructor_probe \
    "$logger_constructor_repository/Sources/LoggerConstructorLeak.swift"
expect_rejection "direct Logger constructor sink" \
    "$logger_constructor_repository" "$logger_constructor_base" \
    "Sources/LoggerConstructorLeak.swift" \
    "direct diagnostic sink requires a reviewed path-free wrapper"

create_repository "optional-logger-sink"
optional_logger_repository=$current_repository
optional_logger_base=$current_base
write_optional_logger_probe \
    "$optional_logger_repository/Sources/OptionalLoggerLeak.swift"
expect_rejection "optional logger sink" \
    "$optional_logger_repository" "$optional_logger_base" \
    "Sources/OptionalLoggerLeak.swift" \
    "direct diagnostic sink requires a reviewed path-free wrapper"

create_repository "function-alias-sink"
function_alias_repository=$current_repository
function_alias_base=$current_base
write_function_alias_probe \
    "$function_alias_repository/Sources/FunctionAliasLeak.swift"
expect_rejection "diagnostic function alias" \
    "$function_alias_repository" "$function_alias_base" \
    "Sources/FunctionAliasLeak.swift" \
    "direct diagnostic sink requires a reviewed path-free wrapper"

for syntax_shape in commented-global commented-member \
    parenthesized-receiver subscript-receiver escaped-global \
    qualified-logger qualified-posix-write qualified-foundation-log \
    qualified-os-log; do
    create_repository "swift-syntax-sink-$syntax_shape"
    syntax_sink_repository=$current_repository
    syntax_sink_base=$current_base
    write_swift_syntax_sink_probe \
        "$syntax_sink_repository/Sources/SwiftSyntaxLeak.swift" \
        "$syntax_shape"
    expect_rejection "Swift syntax sink: $syntax_shape" \
        "$syntax_sink_repository" "$syntax_sink_base" \
        "Sources/SwiftSyntaxLeak.swift" \
        "direct diagnostic sink requires a reviewed path-free wrapper"
done

for named_sink in fatalError preconditionFailure assertionFailure assert \
    precondition printf vprintf puts fputs fprintf perror syslog vsyslog \
    write writev dprintf vdprintf vfprintf fwrite CFShow NSLogv os-logv \
    os-log-error os-log-with-type os-signpost os-signpost-event \
    standard-error standard-output signposter-constructor \
    signposter-member exception-raise; do
    create_repository "named-diagnostic-sink-$named_sink"
    named_sink_repository=$current_repository
    named_sink_base=$current_base
    write_named_diagnostic_sink_probe \
        "$named_sink_repository/Sources/NamedDiagnosticLeak.swift" \
        "$named_sink"
    expect_rejection "named diagnostic sink: $named_sink" \
        "$named_sink_repository" "$named_sink_base" \
        "Sources/NamedDiagnosticLeak.swift" \
        "direct diagnostic sink requires a reviewed path-free wrapper"
done

create_repository "safe-member-write"
safe_member_write_repository=$current_repository
write_safe_member_write_probe \
    "$safe_member_write_repository/Sources/SafeMemberWrite.swift"
expect_acceptance "ordinary member write is not a C diagnostic sink" \
    "$safe_member_write_repository" ""

create_repository "safe-swift-diagnostic-text"
safe_swift_text_repository=$current_repository
safe_swift_text_base=$current_base
write_safe_swift_diagnostic_text_probe \
    "$safe_swift_text_repository/Sources/SafeDiagnosticText.swift"
expect_acceptance "comments and strings are not diagnostic calls" \
    "$safe_swift_text_repository" "$safe_swift_text_base"

create_repository "imported-closure-annotation"
imported_closure_repository=$current_repository
write_imported_closure_annotation_probe \
    "$imported_closure_repository/Sources/ImportedClosure.swift"
expect_acceptance "valid imported closure annotations survive AST scanning" \
    "$imported_closure_repository" ""

create_repository "malformed-swift-source"
malformed_swift_repository=$current_repository
malformed_swift_base=$current_base
write_malformed_swift_probe \
    "$malformed_swift_repository/Sources/Malformed.swift"
expect_rejection "malformed Swift is rejected before AST sink scanning" \
    "$malformed_swift_repository" "$malformed_swift_base" \
    "Sources/Malformed.swift" \
    "Swift source cannot be parsed for diagnostic-sink validation"

create_repository "print-sink"
print_repository=$current_repository
print_base=$current_base
write_sink_probe "$print_repository/Sources/PrintLeak.swift" \
    "$sink_print" "$path_value_name"
expect_rejection "print path sink" "$print_repository" "$print_base" \
    "Sources/PrintLeak.swift"

create_repository "dump-sink"
dump_repository=$current_repository
dump_base=$current_base
write_sink_probe "$dump_repository/Sources/DumpLeak.swift" \
    "$sink_dump" "$display_value_name"
expect_rejection "dump display-name sink" "$dump_repository" "$dump_base" \
    "Sources/DumpLeak.swift"

# Reviewed fixtures use deliberately synthetic identities and roots.
create_repository "synthetic-fixture"
synthetic_repository=$current_repository
synthetic_base=$current_base
mkdir -p "$synthetic_repository/Packages/SpaceTraceKit/Tests/Fixtures"
printf '%s\n' \
    '{"root":"/Fixtures/SpaceTrace/SyntheticRoot","subject":"synthetic-subject-0001","email":"fixture@example.invalid"}' \
    >"$synthetic_repository/Packages/SpaceTraceKit/Tests/Fixtures/synthetic-history.json"
commit_all "$synthetic_repository" "add reviewed synthetic fixture"
expect_acceptance "safe synthetic fixture" "$synthetic_repository" \
    "$synthetic_base"

# Binary fixture bytes are never dumped into diagnostics. A newly introduced
# released-schema binary must be routed through its reviewed sibling manifest.
create_repository "unmanifested-binary"
unmanifested_repository=$current_repository
unmanifested_base=$current_base
unmanifested_root="$unmanifested_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
mkdir -p "$unmanifested_root/v11"
printf '\000SQLite format 3\000synthetic-v11-fixture\000' \
    >"$unmanifested_root/v11/SpaceTrace.sqlite"
expect_rejection "unmanifested binary fixture" "$unmanifested_repository" \
    "$unmanifested_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite"

create_repository "manifested-binary"
manifested_repository=$current_repository
manifested_base=$current_base
manifested_root="$manifested_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
mkdir -p "$manifested_root/v11"
printf '\000SQLite format 3\000synthetic-v11-fixture\000' \
    >"$manifested_root/v11/SpaceTrace.sqlite"
fixture_digest=$(shasum -a 256 "$manifested_root/v11/SpaceTrace.sqlite" | awk '{print $1}')
printf '{\n  "formatVersion": 1,\n  "fixtures": [\n    {\n      "schemaVersion": 11,\n      "relativePath": "v11/SpaceTrace.sqlite",\n      "sha256": "%s"\n    }\n  ]\n}\n' \
    "$fixture_digest" >"$manifested_root/manifest.json"
commit_all "$manifested_repository" "add manifest-routed binary fixture"
expect_rejection "new v1 binary fixture after plan boundary" \
    "$manifested_repository" "$manifested_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite"

create_repository_with_legacy_v1_fixture "unchanged-legacy-v1"
legacy_v1_repository=$current_repository
expect_acceptance "unchanged plan-base v1 fixture" "$legacy_v1_repository" ""

# The frozen plan-base regression evidence is mandatory in every repository
# view until Task 8 installs and gates the independent v2 verifier. Deleting
# both manifest and fixture together must not turn an invalid closure into an
# apparently empty, valid one.
create_repository_with_legacy_v1_fixture "committed-fixture-set-deletion"
committed_fixture_deletion_repository=$current_repository
committed_fixture_deletion_root="$committed_fixture_deletion_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
rm -rf "$committed_fixture_deletion_root"
commit_all "$committed_fixture_deletion_repository" \
    "delete the complete released fixture set"
expect_rejection "committed fixture-set deletion" \
    "$committed_fixture_deletion_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json" \
    "released-schema manifest is absent"

create_repository_with_legacy_v1_fixture "staged-fixture-set-deletion"
staged_fixture_deletion_repository=$current_repository
staged_fixture_deletion_root="$staged_fixture_deletion_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
rm -rf "$staged_fixture_deletion_root"
git -C "$staged_fixture_deletion_repository" add -A
expect_rejection "staged fixture-set deletion" \
    "$staged_fixture_deletion_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json" \
    "released-schema manifest is absent"

create_repository_with_legacy_v1_fixture "worktree-fixture-set-deletion"
worktree_fixture_deletion_repository=$current_repository
worktree_fixture_deletion_root="$worktree_fixture_deletion_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
rm -rf "$worktree_fixture_deletion_root"
expect_rejection "worktree fixture-set deletion" \
    "$worktree_fixture_deletion_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json" \
    "released-schema manifest is absent"

# Manifest, fixture, and (later) generator roles must be regular files. A link
# target string is never accepted as SQLite bytes, in history or the worktree.
create_repository_with_legacy_v1_fixture "committed-fixture-symlink"
committed_symlink_repository=$current_repository
committed_symlink_path="$committed_symlink_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite"
rm "$committed_symlink_path"
ln -s "not-a-database" "$committed_symlink_path"
commit_all "$committed_symlink_repository" "replace fixture with symlink"
expect_rejection "committed fixture symlink" \
    "$committed_symlink_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite" \
    "released-schema artifact is not a regular file"

create_repository_with_legacy_v1_fixture "worktree-fixture-symlink"
worktree_symlink_repository=$current_repository
worktree_symlink_path="$worktree_symlink_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite"
rm "$worktree_symlink_path"
ln -s "not-a-database" "$worktree_symlink_path"
expect_rejection "worktree fixture symlink" \
    "$worktree_symlink_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite" \
    "released-schema artifact is not a regular file"

create_repository_with_legacy_v1_fixture "staged-fixture-symlink"
staged_symlink_repository=$current_repository
staged_symlink_path="$staged_symlink_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite"
rm "$staged_symlink_path"
ln -s "not-a-database" "$staged_symlink_path"
git -C "$staged_symlink_repository" add \
    Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite
expect_rejection "staged fixture symlink" \
    "$staged_symlink_repository" "" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite" \
    "released-schema artifact is not a regular file"

for view in committed staged worktree; do
    create_repository_with_legacy_v1_fixture "${view}-manifest-symlink"
    manifest_symlink_repository=$current_repository
    manifest_symlink_path="$manifest_symlink_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json"
    rm "$manifest_symlink_path"
    ln -s "not-a-manifest" "$manifest_symlink_path"
    case "$view" in
        committed) commit_all "$manifest_symlink_repository" "replace manifest with symlink" ;;
        staged) git -C "$manifest_symlink_repository" add \
            Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json ;;
        worktree) ;;
    esac
    expect_rejection "$view manifest symlink" \
        "$manifest_symlink_repository" "" \
        "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/manifest.json" \
        "released-schema artifact is not a regular file"
done

# A plausibly shaped v2 manifest still fails when it omits the independent
# verifier. A self-authored generator and self-asserted digests are not proof.
create_repository "manifest-v2-routing"
v2_repository=$current_repository
v2_base=$current_base
v2_root="$v2_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
v2_generator="Scripts/Fixtures/generate-released-schema-fixtures.sh"
mkdir -p "$v2_root/v11" "$v2_repository/${v2_generator%/*}"
printf '#!/usr/bin/env bash\nprintf "deterministic synthetic fixture generator\\n"\n' \
    >"$v2_repository/$v2_generator"
printf '\000SQLite format 3\000synthetic-v2-routed-fixture\000' \
    >"$v2_root/v11/SpaceTrace.sqlite"
v2_digest=$(shasum -a 256 "$v2_root/v11/SpaceTrace.sqlite" | awk '{print $1}')
write_v2_released_fixture_manifest "$v2_root/manifest.json" 11 \
    "v11/SpaceTrace.sqlite" "$v2_digest" "$v2_generator" \
    "1" "spacetrace-v11-seed" \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
commit_all "$v2_repository" "add manifest-v2 routed fixture"
expect_rejection "manifest-v2 requires the independent verifier" \
    "$v2_repository" "$v2_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite" \
    "format-2 fixture verifier is absent"

# The exact reviewed v2 closure is accepted only when its verifier, generators,
# source inputs and all seven frozen fixtures are present in the same repository.
create_repository "reviewed-manifest-v2"
reviewed_v2_repository=$current_repository
reviewed_v2_base=$current_base
mkdir -p \
    "$reviewed_v2_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures" \
    "$reviewed_v2_repository/Packages/SpaceTraceKit/Sources/SpaceTracePersistence" \
    "$reviewed_v2_repository/Scripts/Fixtures"
cp -R "$repository_root/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas" \
    "$reviewed_v2_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/"
cp "$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteEventJournalRepository.swift" \
    "$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalFindingSchema.swift" \
    "$repository_root/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/SQLiteHistoricalCorrectionSchema.swift" \
    "$reviewed_v2_repository/Packages/SpaceTraceKit/Sources/SpaceTracePersistence/"
cp "$repository_root/Scripts/Fixtures/generate-released-schema-v10-fixture.sh" \
    "$repository_root/Scripts/Fixtures/generate-released-schema-v11-fixture.sh" \
    "$repository_root/Scripts/Fixtures/generate-released-schema-v12-fixture.sh" \
    "$reviewed_v2_repository/Scripts/Fixtures/"
cp "$repository_root/Scripts/verify-released-schema-fixtures.sh" \
    "$reviewed_v2_repository/Scripts/"
chmod 0755 "$reviewed_v2_repository/Scripts/Fixtures/"*.sh \
    "$reviewed_v2_repository/Scripts/verify-released-schema-fixtures.sh"
commit_all "$reviewed_v2_repository" "add independently reviewed v2 fixtures"
expect_acceptance "reviewed manifest-v2 closure" \
    "$reviewed_v2_repository" "$reviewed_v2_base"

for view in committed staged worktree; do
    generator_symlink_repository="$temporary_root/${view}-generator-symlink"
    cp -R "$reviewed_v2_repository" "$generator_symlink_repository"
    generator_symlink_path="$generator_symlink_repository/Scripts/Fixtures/generate-released-schema-v11-fixture.sh"
    rm "$generator_symlink_path"
    ln -s "not-a-generator" "$generator_symlink_path"
    case "$view" in
        committed) commit_all "$generator_symlink_repository" "replace generator with symlink" ;;
        staged) git -C "$generator_symlink_repository" add \
            Scripts/Fixtures/generate-released-schema-v11-fixture.sh ;;
        worktree) ;;
    esac
    expect_rejection "$view generator symlink" \
        "$generator_symlink_repository" "$reviewed_v2_base" \
        "Scripts/Fixtures/generate-released-schema-v11-fixture.sh" \
        "format-2 fixture verifier rejected the current closure"
done

for payload in text opaque; do
    invalid_fixture_repository="$temporary_root/${payload}-sqlite-fixture"
    cp -R "$reviewed_v2_repository" "$invalid_fixture_repository"
    invalid_fixture_path="$invalid_fixture_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite"
    if [[ "$payload" == text ]]; then
        printf 'this is not a SQLite database\n' >"$invalid_fixture_path"
    else
        printf '\001\002\003\004opaque-binary\000' >"$invalid_fixture_path"
    fi
    expect_rejection "$payload sqlite fixture" \
        "$invalid_fixture_repository" "$reviewed_v2_base" \
        "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite" \
        "format-2 fixture verifier rejected the current closure"
done

printf '\n# generator drift\n' >> \
    "$reviewed_v2_repository/Scripts/Fixtures/generate-released-schema-v11-fixture.sh"
expect_rejection "manifest-v2 rejects generator drift" \
    "$reviewed_v2_repository" "$reviewed_v2_base" \
    "Scripts/Fixtures/generate-released-schema-v11-fixture.sh" \
    "format-2 fixture verifier rejected the current closure"

# The only accepted binary layout is exactly v<digits>/SpaceTrace.sqlite.
# A broad glob must not admit an extra nested path even if a manifest lists it.
create_repository_with_legacy_v1_fixture "nested-binary"
nested_repository=$current_repository
nested_base=$current_base
nested_root="$nested_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
mkdir -p "$nested_root/v11/nested"
printf '\000SQLite format 3\000synthetic-nested-v11-fixture\000' \
    >"$nested_root/v11/nested/SpaceTrace.sqlite"
commit_all "$nested_repository" "add invalid nested binary fixture"
expect_rejection "strict released binary path" "$nested_repository" \
    "$nested_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/nested/SpaceTrace.sqlite" \
    "unreviewed binary artifact"

# Format 1 is frozen byte-for-byte at the plan boundary; split or duplicate
# rows cannot be used to weaken the existing fixture/digest association.
create_repository_with_legacy_v1_fixture "split-manifest-binding"
split_repository=$current_repository
split_base=$current_base
split_root="$split_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
mkdir -p "$split_root/v11"
printf '\000SQLite format 3\000synthetic-split-binding\000' \
    >"$split_root/v11/SpaceTrace.sqlite"
split_digest=$(shasum -a 256 "$split_root/v11/SpaceTrace.sqlite" | awk '{print $1}')
printf '{\n  "formatVersion": 1,\n  "fixtures": [\n    {\n      "schemaVersion": 11,\n      "relativePath": "v11/Other.sqlite",\n      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"\n    },\n    {\n      "schemaVersion": 12,\n      "relativePath": "v11/SpaceTrace.sqlite",\n      "sha256": "%s"\n    }\n  ]\n}\n' \
    "$split_digest" >"$split_root/manifest.json"
commit_all "$split_repository" "add split manifest proof"
expect_rejection "frozen v1 rejects split manifest binding" "$split_repository" \
    "$split_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite" \
    "format-1 fixture manifest differs from the frozen plan base"

create_repository_with_legacy_v1_fixture "duplicate-manifest-binding"
duplicate_repository=$current_repository
duplicate_base=$current_base
duplicate_root="$duplicate_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
mkdir -p "$duplicate_root/v11"
printf '\000SQLite format 3\000synthetic-duplicate-binding\000' \
    >"$duplicate_root/v11/SpaceTrace.sqlite"
duplicate_digest=$(shasum -a 256 \
    "$duplicate_root/v11/SpaceTrace.sqlite" | awk '{print $1}')
printf '{\n  "formatVersion": 1,\n  "fixtures": [\n    {\n      "schemaVersion": 11,\n      "relativePath": "v11/SpaceTrace.sqlite",\n      "sha256": "%s"\n    },\n    {\n      "schemaVersion": 11,\n      "relativePath": "v11/SpaceTrace.sqlite",\n      "sha256": "%s"\n    }\n  ]\n}\n' \
    "$duplicate_digest" "$duplicate_digest" \
    >"$duplicate_root/manifest.json"
commit_all "$duplicate_repository" "add duplicate manifest proof"
expect_rejection "frozen v1 rejects duplicate manifest binding" \
    "$duplicate_repository" \
    "$duplicate_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v11/SpaceTrace.sqlite" \
    "format-1 fixture manifest differs from the frozen plan base"

# An unchanged frozen manifest must revalidate its referenced binary in each
# Git view; a fixture-only drift cannot hide behind the old manifest digest.
create_repository_with_legacy_v1_fixture "committed-binary-drift"
committed_drift_repository=$current_repository
committed_drift_root="$committed_drift_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
committed_drift_base=$(git -C "$committed_drift_repository" rev-parse HEAD)
printf '\000SQLite format 3\000changed-committed-fixture\000' \
    >"$committed_drift_root/v9/SpaceTrace.sqlite"
commit_all "$committed_drift_repository" "drift committed fixture only"
expect_rejection "committed binary-only digest drift" \
    "$committed_drift_repository" "$committed_drift_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite" \
    "released-schema fixture digest mismatch"

create_repository_with_legacy_v1_fixture "staged-binary-drift"
staged_drift_repository=$current_repository
staged_drift_root="$staged_drift_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
staged_drift_base=$(git -C "$staged_drift_repository" rev-parse HEAD)
printf '\000SQLite format 3\000changed-staged-fixture\000' \
    >"$staged_drift_root/v9/SpaceTrace.sqlite"
git -C "$staged_drift_repository" add \
    Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite
expect_rejection "staged binary-only digest drift" \
    "$staged_drift_repository" "$staged_drift_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite" \
    "released-schema fixture digest mismatch"

create_repository_with_legacy_v1_fixture "worktree-binary-drift"
worktree_drift_repository=$current_repository
worktree_drift_root="$worktree_drift_repository/Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas"
worktree_drift_base=$(git -C "$worktree_drift_repository" rev-parse HEAD)
printf '\000SQLite format 3\000changed-worktree-fixture\000' \
    >"$worktree_drift_root/v9/SpaceTrace.sqlite"
expect_rejection "worktree binary-only digest drift" \
    "$worktree_drift_repository" "$worktree_drift_base" \
    "Packages/SpaceTraceKit/Tests/SpaceTracePersistenceTests/Fixtures/ReleasedSchemas/v9/SpaceTrace.sqlite" \
    "released-schema fixture digest mismatch"

readonly expected_case_count=126
if (( passed_cases + failed_cases != expected_case_count )); then
    record_contract_failure "case inventory" \
        "expected $expected_case_count cases, observed $((passed_cases + failed_cases))"
fi

if (( failed_cases > 0 )); then
    printf 'historical ledger privacy checker contract: RED (%s failed, %s passed)\n' \
        "$failed_cases" "$passed_cases" >&2
    exit 1
fi

printf 'historical ledger privacy checker contract: PASS (%s cases)\n' "$passed_cases"
