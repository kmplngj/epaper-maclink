#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .local
# Command Line Tools omit XCTest. The same behavior checks have a standalone runner.
MACLINK_SDK="${MACLINK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -sdk "$MACLINK_SDK" macos/Sources/MacLinkCore/*.swift macos/Tests/MacLinkCoreTests/RulesTests.swift -o .local/check-rules
.local/check-rules
