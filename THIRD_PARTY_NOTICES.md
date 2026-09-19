# License scope and third-party notices

## MacLink

Copyright (c) 2026 Jan Kampling.

The root [MIT license](LICENSE) applies to original MacLink code and documentation except **all source files in `firmware/` and `scripts/build-firmware.py`**, which are **GPL-3.0-only** under [firmware/LICENSE](firmware/LICENSE). Third-party assets and dependencies retain their own licenses; none are relicensed by the root MIT file.

## OpenDisplay Firmware

- Project: [OpenDisplay/Firmware](https://github.com/OpenDisplay/Firmware)
- Pinned release: **2.26.5**, commit [`7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb`](https://github.com/OpenDisplay/Firmware/tree/7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb)
- License: **GNU GPL version 3**, [upstream text](https://github.com/OpenDisplay/Firmware/blob/7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb/LICENSE), copied verbatim to [firmware/LICENSE](firmware/LICENSE).

OpenDisplay is downloaded into ignored `.local/vendor/` during a firmware build. MacLink adds HTTP delivery, panel streaming, and sleep scheduling and patches two upstream source files; [firmware documentation](docs/firmware.md) records those changes. Upstream source and its dependencies retain their copyright notices and applicable licenses. The resulting combined firmware is GPLv3, not MIT. Binary distribution requires complete Corresponding Source and applicable installation information, not just these adapter files.

## Swift dependencies

| Component | Pinned version | License and attribution |
| --- | --- | --- |
| [HAKit](https://github.com/home-assistant/HAKit) | 0.4.18 | [Apache 2.0](licenses/HAKit-Apache-2.0.md), Home Assistant contributors; see upstream source notices |
| [Starscream, bgoncal fork](https://github.com/bgoncal/Starscream) | 4.0.9 | [Apache 2.0](licenses/Starscream-Apache-2.0.txt), Copyright (c) 2014–2023 Dalton Cherry |
| [PromiseKit](https://github.com/mxcl/PromiseKit) | 8.2.0 | [MIT](licenses/PromiseKit-MIT.txt), Copyright 2016–present Max Howell |

PromiseKit is resolved by HAKit's optional product dependency; MacLink selects the `HAKit` product, not `HAKit+PromiseKit`. Exact revisions are recorded in [Package.resolved](macos/Package.resolved). The build bundles these license texts with the app.

## Bundled fonts

The font files are unmodified upstream assets. Their license texts ship beside the fonts in the app resource bundle.

| Font | Source | License |
| --- | --- | --- |
| TRMNL12 Regular/Bold, TRMNL16 Regular/Bold, TRMNL21 Bold | [TRMNL framework, commit ce43e4dc](https://github.com/usetrmnl/trmnl-framework/tree/ce43e4dcda6dad14217fd06cc3e109da2b9e0988/public/fonts) | [SIL OFL 1.1](macos/Sources/MacLink/Resources/Fonts/OFL.txt), Copyright © 2026 Heavyweight Digital Type Foundry s.r.o.; Copyright 2016 The Inter Project Authors |
| Noto Emoji | [Google Fonts, commit 809e4d8b](https://github.com/google/fonts/tree/809e4d8b8d7e9364a914909bb777679606c178b8/ofl/notoemoji), `NotoEmoji[wght].ttf` stored as `NotoEmoji.ttf` | [SIL OFL 1.1](macos/Sources/MacLink/Resources/Fonts/NotoEmoji-OFL.txt), Copyright 2013 Google LLC |

## Other downloaded dependencies

The server's Python dependency versions are recorded in `server/uv.lock`. Firmware tooling and upstream PlatformIO dependencies are downloaded during setup/build, with their own license metadata. They are not vendored into this repository. Redistribution of an application image, container, or firmware must also retain the notices and satisfy the terms of the dependencies included in that artifact.
