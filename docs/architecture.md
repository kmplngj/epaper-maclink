# Architecture

MacLink has three independently running parts: a native macOS publisher, a small HTTP store, and a sleeping e-paper client.

## Rendering and updates

The Mac reads selected Calendar and Reminders sources with EventKit and selected Home Assistant values through HAKit's WebSocket connection. `MacLinkCore` holds display configuration, deduplication, day packing, and sensor sampling rules. AppKit/CoreText render the final page.

The dashboard uses native 12-, 16-, and 21-pixel TRMNL fonts, integer baselines, and no antialiasing. Noto Emoji supplies monochrome symbols. Sensor text can use Foundation's inline Markdown parser, mapped back onto the same fonts.

The footer measures its contents before calendar layout. It supports up to four values in at most two groups of rows, with one to three lines per item. Complete days fit into the space above it. No footer means no space reserved for it.

After rendering, the Mac quantizes pixels to black and white. SHA-256 covers the ASCII prefix `mono1:white=1:msb:WIDTH:HEIGHT:` followed by packed, row-major bytes, most significant bit first, with white represented by 1. Identical final pixels suppress uploads. The server also compares final pixels independently of PNG encoding and metadata.

## Delivery contract

| Endpoint | Credential | Purpose |
| --- | --- | --- |
| `GET /health` | None | Health/version without personal content |
| `GET /v1/displays` | Admin | List displays and delivery state |
| `POST /v1/displays` | Admin | Create a display and return its device token |
| `PATCH /v1/displays/{id}` | Admin | Rename and set polling interval |
| `POST /v1/displays/{id}/token` | Admin | Rotate a device token |
| `PATCH /v1/displays/{id}/battery` | Admin | Configure interval, daily window, and time zone |
| `PUT /v1/displays/{id}/image` | Admin | Publish PNG with revision and observation time |
| `GET /v1/displays/{id}` | Admin or matching device | Status |
| `GET /v1/displays/{id}/image` | Admin or matching device | PNG preview with ETag |
| `GET /v1/displays/{id}/frame` | Admin or matching device | Packed monochrome bytes and schedule headers |
| `POST /v1/displays/{id}/ack` | Admin or matching device | Confirm the displayed digest |

Uploads are limited to 4 MiB and checked against the registered dimensions and revision. PNG and raw representations use distinct ETags. An unchanged request returns 304; a raw-frame request outside allowed update hours returns 204 with scheduling headers.

For the supported display, a frame is 48,000 bytes. Firmware streams it into the panel, validates its hash before refreshing, and acknowledges successful output. The server's time and UTC update windows are cached in RTC memory for up to 30 days. Cold starts and expired policy caches need a connection; RTC drift can affect exact wake times.

## Storage and boundaries

- **Mac:** selections in Application Support, credentials in Keychain, sensor readings in memory.
- **Server:** SQLite records, hashed device tokens, latest PNG and packed frame. Docker mounts `/data` persistently.
- **Display:** generated firmware credentials and RTC state for the displayed hash and schedule.
- **Source checkout:** ignored `.local/` for toolchains, private provisioning files, backups, and diagnostics.

The server never reads Apple accounts or Home Assistant directly. Its last image may be out of date while the Mac is asleep. One coordinated publisher should own each display to avoid conflicting revisions. The supplied deployment is designed for a trusted LAN.
