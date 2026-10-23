#!/bin/sh
set -eu

find_project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
find_build=$(mktemp -d "${TMPDIR:-/tmp}/umarkdown-find-tests.XXXXXX")
trap 'rm -rf "$find_build"' EXIT

xcrun swiftc -module-cache-path "$find_build/ModuleCache" \
    "$find_project/UMarkdown/BufferedMarkdownView.swift" \
    "$find_project/UMarkdown/FindBarView.swift" \
    "$find_project/UMarkdown/PreviewSearch.swift" \
    "$find_project/UMarkdown/WindowPlacement.swift" \
    "$find_project/UMarkdown/MarkdownPreviewWindowController.swift" \
    "$find_project/Tests/FindTests.swift" -o "$find_build/FindTests"
"$find_build/FindTests" "$find_project" "$@"
