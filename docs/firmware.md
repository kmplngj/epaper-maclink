# Firmware

## Supported hardware

The current adapter targets the Seeed XIAO ESP32-C3 with the 7.5-inch monochrome 800 × 480 panel (`xiao-75-c3` / `ep75-800x480` in OpenDisplay's simple configuration). Other panels and controllers supported by upstream OpenDisplay are not automatically supported by MacLink.

## USB setup

Install `uv`, connect the display over USB, and select it in MacLink. In **Firmware**:

1. Select this repository under **Firmware tools**, if the source folder was moved.
2. Prepare the tools. This creates an isolated environment under `.local/venv`.
3. Enter the display's 2.4 GHz Wi-Fi details and select its USB connection.
4. Build the firmware for the selected display.
5. Flash after the build completes, keeping USB connected.

The helper checks the build fingerprint, image hash, and partition layout before writing. It requires a single unencrypted app partition at `0x10000`, size `0x300000`. Before the first write for a device, it preserves a full 4 MiB flash backup and SHA-256 digest under `.local/firmware/backups/<device-mac>/`. The app partition is then written at `0x10000`.

Keep those original backups. Wi-Fi details, device tokens, generated headers, private diagnostic images, and compiled firmware remain under ignored `.local/`. A configured binary contains credentials and must not be published.

## Reproducible source inputs

The build script fetches [OpenDisplay Firmware 2.26.5](https://github.com/OpenDisplay/Firmware/tree/7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb), checks commit `7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb`, and adds:

- `maclink_pull.cpp` / `.h`: authenticated HTTP frame download, validation, acknowledgment, and sleep.
- `maclink_panel.inc`: streaming into upstream's panel session and refresh helpers.
- `maclink_schedule.h`: cached daily windows and next-wake calculations.
- A guarded call in upstream `src/main.cpp` and an include at the end of `src/display_service.cpp`, enabled by `MACLINK_HTTP_PULL`.
- A board-specific factory configuration and local PlatformIO build flags.

The complete patching procedure is in [`scripts/build-firmware.py`](../scripts/build-firmware.py). Tool preparation pins PlatformIO 6.2.0, py-opendisplay 7.16.0, pyserial 3.5, and esptool 5.4.0. Upstream's own PlatformIO configuration controls further dependencies; this is not a claim of bit-for-bit reproducible binaries.

For development, `--compile-only` allows missing Wi-Fi credentials but still needs a device configuration. `--debug-awake` disables normal deep sleep. `--usb-panel-test /absolute/path/to/image.png` creates a private offline panel/timer diagnostic. These are diagnostic builds, not normal installations. Use `python3 scripts/monitor-display.py --port /dev/cu.usbmodemYOURPORT` to passively capture USB output across sleep/wake cycles.

## Licensing and distribution

OpenDisplay's pinned release carries **GNU GPL version 3**. The MacLink firmware files and the script that patches them into upstream are licensed **GPL-3.0-only**, with the full text in [`firmware/LICENSE`](../firmware/LICENSE). The additions are identified as MacLink modifications, copyright 2026 Jan Kampling; upstream attribution remains intact in its checkout.

The combined firmware is GPLv3 software. The root MIT license applies to the independently running Mac app and server, not to that combined firmware. Third-party components within upstream retain their own applicable notices.

This repository publishes source additions and build instructions, not firmware binaries. If you distribute a combined binary, also provide its complete Corresponding Source under GPLv3, including the matching upstream source, MacLink changes, necessary build/configuration scripts, and dependency source/notices required by their licenses. Provide any installation information required by GPLv3. A link to this patch repository alone is not a complete source bundle. Use non-secret example configuration rather than distributing your Wi-Fi credentials or tokens.
