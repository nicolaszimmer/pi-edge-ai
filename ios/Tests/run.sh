#!/usr/bin/env bash
# Tests for the parts of Pi Chat that are plain Swift (no SwiftUI): the Markdown
# and maths reader, the chat archive and the chat store. Needs only swiftc:
# a Mac with Xcode, or Linux with a Swift toolchain (swift.org).
#
#   ios/Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")"
app=../PiChat
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

echo "Markdown"
swiftc -O -swift-version 5 "$app/Markdown.swift" Markdown/main.swift -o "$build/markdown"
"$build/markdown" Fixtures/pythagoras.md

echo "Chat archive"
swiftc -swift-version 5 "$app/Markdown.swift" "$app/ChatArchive.swift" ChatArchive/main.swift -o "$build/archive"
"$build/archive"

echo "Chat store"
swiftc -swift-version 5 "$app/Markdown.swift" "$app/ChatArchive.swift" "$app/ChatStore.swift" \
    ChatStore/LlamaClientStub.swift ChatStore/main.swift -o "$build/store"
mkdir -p "$build/docs"
"$build/store" "$build/docs"
