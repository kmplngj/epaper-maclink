# Development

## Build the Mac app

Use macOS 14+ with a Swift 6 toolchain, a macOS SDK, and Git. The package declares Swift tools 6.0 and uses Swift 5 language mode. The integration harness currently expects the newer Swift Build output layout; it has been checked with Apple Swift 6.4 and the macOS 26.5 SDK.

```sh
sh scripts/build-mac.sh
```

The script uses the SDK selected by `xcrun`. Override it when testing another installed SDK:

```sh
MACLINK_SDK=/path/to/MacOSX.sdk sh scripts/build-mac.sh
```

The output is `dist/MacLink.app`. Resources and dependency licenses are bundled. The script uses an available signing identity, falling back to ad-hoc signing. Set `MACLINK_SIGN_IDENTITY` to select an identity, or `-` for ad-hoc signing. Keep the app at a stable location when testing EventKit permissions and launch at login.

`macos/Package.resolved` and `server/uv.lock` are committed. Build output, virtual environments, and credentials are ignored.

## Checks

From the repository root:

```sh
sh scripts/check-mac.sh
sh scripts/check-mac-integration.sh
uv run --project server pytest server/tests -q
python3 -m unittest discover -s scripts -p 'test_*.py'
mkdir -p .local
c++ -std=c++11 scripts/check-firmware-schedule.cpp -o .local/check-firmware-schedule
.local/check-firmware-schedule
```

The Mac checks accept the same `MACLINK_SDK` override. The core suite has a standalone runner so it works when Command Line Tools omit XCTest. The integration harness links production renderer/HA code, checks exact monochrome output, and runs HAKit against a loopback WebSocket fixture. It does not use live HA credentials or modify your settings. Synthetic dashboard PNGs are written under `.local/`.

Python tests cover server authentication, image revisions/deduplication, scheduling, and the guarded firmware workflow with a mocked USB device. The C++ check exercises firmware wake calculations without hardware. These checks do not flash a display; physical panel validation is separate.

## Working locally

The [setup guide](setup.md) covers Docker. To run Python directly, use Python 3.13+ through `uv`, set a private `MACLINK_ADMIN_TOKEN` of at least 24 characters, and run:

```sh
cd server
uv run fastapi dev maclink_server/app.py --port 8099
```

Keep generated frames and any real family data under `.local/`. Public examples should use synthetic data, as the README screenshot does. Keep the original flash backups when cleaning a checkout.

Before contributing firmware changes, read the [licensing and source requirements](firmware.md#licensing-and-distribution). App/server changes remain MIT; firmware integration changes remain GPLv3.
