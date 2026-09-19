# Setup

## Start the server

Copy `compose.yaml`, `.env.example`, and the `server/` directory to your server, or clone the repository there. Docker Compose builds the service with its locked Python dependencies.

```sh
cp .env.example .env
chmod 600 .env
python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
```

Paste the generated value into `MACLINK_ADMIN_TOKEN` in `.env`. Set `MACLINK_BIND_ADDRESS` to the server's LAN IPv4 address if a physical display will connect. The default `127.0.0.1` allows connections only from the server itself.

```sh
docker compose up --build -d --wait
curl http://127.0.0.1:8099/health
```

For the health check, replace `127.0.0.1` with the configured bind address. The response should report `"status":"ok"`.

The supplied firmware uses HTTP on a trusted LAN. Restrict port 8099 to your trusted clients; do not expose it to the internet. Docker-published ports need appropriate Docker/host firewall rules. The administrator token can publish images and manage displays, while each device receives its own read/acknowledgment token.

The named Docker volume `maclink-data` stores display records and the latest images. Keep it backed up; `docker compose down -v` removes it. Images contain the information you choose to display.

### Optional SSH deployment helper

From your Mac, with SSH, rsync, and Docker Compose already configured on the target:

```sh
python3 scripts/deploy-server.py --host your-ssh-host --address 10.0.0.10
```

Replace both examples with your server details. The target needs noninteractive sudo for creating `/srv/epaper-maclink` and permission to run Docker. The helper creates or reuses `.local/server.json`, deploys the service, and writes a private bootstrap file for the Mac app. It does not configure your firewall.

## Connect the Mac app

Build and install using the commands in the [README](../README.md), then open **Connection** in MacLink. Enter the server URL, such as `http://10.0.0.10:8099`, and the administrator token from `.env`. Credentials are stored in macOS Keychain.

Add a display, give it a name, and select its **Content**. Allow Calendar and Reminders access when requested, then choose the calendars and lists to show. Calendar accounts must already be configured in macOS; MacLink reads them through EventKit.

Each calendar has an optional abbreviation of up to six characters. Each reminder list has its own sort order. Completed reminders and canceled events are excluded. Today's earlier appointments stay visible. Matching events across calendars are shown once with a calendar count.

**Fit as many days as possible** considers up to 31 days and publishes complete days. Turn it off to choose a shorter lookahead. Reminder lists occupy at most 40% of the right column, with an overflow count. If even a smaller native font cannot fit today's full agenda, MacLink reports the capacity issue instead of publishing a partial day.

Use **Preview** to inspect the exact output and delivery status. Closing the window leaves MacLink in the menu bar; quitting stops updates. **Open MacLink at login** is available under Connection.

## Home Assistant

Enter your Home Assistant URL and a long-lived access token in **Home Assistant**, then select **Connect / Retry**. The connection is shared by displays and the token stays in Keychain. MacLink reads sensor states; it does not call services or change entity states.

For each display:

1. Enable **Show sensor footer** and select **Add sensor**.
2. Search for a `sensor` or `binary_sensor` by name or entity ID.
3. Choose its state or a scalar attribute. Attributes are useful for longer text summaries.
4. Configure the label, unit, decimals, binary on/off wording, and text format.
5. Arrange up to four items, select a sampling interval, and allow one to three lines per item.

Markdown uses Foundation's inline parser. `**bold**` and `*emphasis*` use the bold pixel font; links show their labels. Labels themselves are literal text. Images are not fetched. Headings, tables, HTML, and dashboard cards are not supported.

Short values share a row. Longer summaries can occupy a second row, with widths based on measured text. When multiple lines are allowed, an overflowing summary can break at ` | ` separators. Text that still cannot fit ends with an ellipsis.

Values arrive continuously but are sampled per display, every 30 minutes by default. Choose **Sample now** or **Check for changes** for an immediate sample. Rounded, unchanged values produce unchanged pixels. There is no footer timestamp row.

On disconnection, last sampled values get an **Offline** prefix. Missing and unavailable entities have explicit text. The cache is in memory: restarting the app requires fresh HA data. Both new readings and offline indicators can be delayed while the Mac sleeps.

## Provision and schedule the display

Follow the [firmware guide](firmware.md) for USB setup. Under **Battery**, choose a check interval from 1 minute to 24 hours and an optional daily update window with its time zone. Overnight windows are supported.

The interval controls sleep after each check; a check refreshes the panel only for changed pixels. Outside its window, the device sleeps until the next opening. A sleeping device receives new settings on its next connection. Cold boots require an initial connection to learn the time and schedule.

The Mac reconciles on content changes, wake, and time boundaries, with additional discretionary background checks. It does not force the Mac awake. The server continues to serve the last image until the Mac publishes again.
