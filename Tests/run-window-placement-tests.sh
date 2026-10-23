#!/bin/sh
set -eu

placement_project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
placement_build=$(mktemp -d "${TMPDIR:-/tmp}/umarkdown-placement-tests.XXXXXX")
trap 'rm -rf "$placement_build"' EXIT

xcrun swiftc -module-cache-path "$placement_build/ModuleCache" \
    "$placement_project/UMarkdown/WindowPlacement.swift" \
    "$placement_project/Tests/WindowPlacementTests.swift" -o "$placement_build/WindowPlacementTests"
"$placement_build/WindowPlacementTests"
