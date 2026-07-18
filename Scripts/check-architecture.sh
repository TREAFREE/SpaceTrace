#!/bin/zsh

set -euo pipefail

readonly domain_directory="Packages/SpaceTraceKit/Sources/SpaceTraceDomain"
readonly forbidden_imports='^(import|@_exported import)[[:space:]]+(AppKit|CoreServices|DiskArbitration|GRDB|SQLite3|SwiftUI)([[:space:]]|$)'

if [[ ! -d "${domain_directory}" ]]; then
    print -u2 "Missing domain source directory: ${domain_directory}"
    exit 1
fi

if rg --line-number "${forbidden_imports}" "${domain_directory}"; then
    print -u2 "SpaceTraceDomain contains a forbidden platform or persistence import."
    exit 1
fi

print "Architecture boundaries are valid."
