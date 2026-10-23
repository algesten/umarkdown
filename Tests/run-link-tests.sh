#!/bin/sh
set -eu

link_project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
link_build=$(mktemp -d "${TMPDIR:-/tmp}/umarkdown-link-tests.XXXXXX")
trap 'rm -rf "$link_build"' EXIT

xcrun swiftc -module-cache-path "$link_build/ModuleCache" \
    "$link_project/UMarkdown/BufferedMarkdownView.swift" \
    "$link_project/UMarkdown/FindBarView.swift" \
    "$link_project/UMarkdown/PreviewSearch.swift" \
    "$link_project/UMarkdown/WindowPlacement.swift" \
    "$link_project/UMarkdown/MarkdownPreviewWindowController.swift" \
    "$link_project/Tests/LinkNavigationTests.swift" -o "$link_build/LinkNavigationTests"
"$link_build/LinkNavigationTests" "$link_project" "$@"
