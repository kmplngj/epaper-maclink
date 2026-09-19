#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .local
MACLINK_SDK="${MACLINK_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
swift build --package-path macos -c release --sdk "$MACLINK_SDK"
swiftc -parse-as-library -sdk "$MACLINK_SDK" \
  -I macos/.build/release \
  macos/Sources/MacLink/DataError.swift macos/Sources/MacLink/HomeAssistant.swift \
  macos/Sources/MacLink/Renderer.swift macos/Sources/MacLink/SensorFooterRenderer.swift \
  macos/.build/out/Intermediates.noindex/MacLink.build/Release/MacLink-p.build/DerivedSources/resource_bundle_accessor.swift \
  macos/.build/release/MacLinkCore.o macos/.build/release/HAKit.o \
  macos/.build/release/Starscream.o scripts/check-mac-integration.swift \
  -o .local/check-mac-integration
ditto macos/.build/release/MacLink_MacLink.bundle .local/MacLink_MacLink.bundle
uv run scripts/check-home-assistant.py
