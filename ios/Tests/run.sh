#!/usr/bin/env bash
# Tests for the parts of Pi Chat that are plain Swift (no SwiftUI): the Markdown
# and maths reader, the chat archive, tool calls and the chat store. Needs only
# swiftc: a Mac with Xcode, or Linux with a Swift toolchain (swift.org).
#
#   ios/Tests/run.sh
#
# With a server whose web tools are on, it also runs LlamaClient against it:
#
#   PICHAT_TEST_SERVER=http://pi-llm.local:8080 PICHAT_TEST_KEY=sk-pi-… \
#   PICHAT_TEST_MODEL=gemma-4-e2b ios/Tests/run.sh
set -euo pipefail
cd "$(dirname "$0")"
app=../PiChat
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

echo "Markdown"
swiftc -O -swift-version 5 "$app/Markdown.swift" Markdown/main.swift -o "$build/markdown"
"$build/markdown" Fixtures/pythagoras.md

echo "Chat archive"
swiftc -swift-version 5 "$app/Markdown.swift" "$app/ChatArchive.swift" "$app/ToolCalls.swift" ChatArchive/main.swift -o "$build/archive"
"$build/archive"

echo "Tool calls"
swiftc -swift-version 5 "$app/ToolCalls.swift" "$app/LlamaWire.swift" "$app/LlamaClient.swift" \
    Live/URLSessionBytes.swift Tools/main.swift -o "$build/tools"
"$build/tools" Fixtures

echo "Chat store"
swiftc -swift-version 5 "$app/Markdown.swift" "$app/ChatArchive.swift" "$app/ChatStore.swift" \
    "$app/ToolCalls.swift" "$app/LlamaWire.swift" \
    ChatStore/LlamaClientStub.swift ChatStore/main.swift -o "$build/store"
mkdir -p "$build/docs"
"$build/store" "$build/docs"

# Only with a server: the real LlamaClient and the Pi's web tools, end to end.
if [[ -n "${PICHAT_TEST_SERVER:-}" ]]; then
    echo "Live server"
    swiftc -swift-version 5 "$app/ToolCalls.swift" "$app/LlamaWire.swift" "$app/LlamaClient.swift" \
        Live/URLSessionBytes.swift Live/main.swift -o "$build/live"
    "$build/live"
fi
