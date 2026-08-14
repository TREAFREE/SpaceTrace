#!/bin/zsh

set -euo pipefail

command -v rg >/dev/null 2>&1 || {
    print -u2 "Missing required verification tool: rg"
    exit 69
}

readonly forbidden_imports='^(import|@_exported import)[[:space:]]+(AppKit|CoreServices|DiskArbitration|GRDB|SQLite3|SwiftUI)([[:space:]]|$)'
readonly core_directories=(
    "Packages/SpaceTraceKit/Sources/SpaceTraceDomain"
    "Packages/SpaceTraceKit/Sources/SpaceTraceAttribution"
)

for core_directory in "${core_directories[@]}"; do
    if [[ ! -d "${core_directory}" ]]; then
        print -u2 "Missing core source directory: ${core_directory}"
        exit 1
    fi

    if rg --line-number "${forbidden_imports}" "${core_directory}"; then
        print -u2 "Core module contains a forbidden platform or persistence import: ${core_directory}"
        exit 1
    fi
done

print "Architecture boundaries are valid."
