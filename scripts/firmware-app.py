"""Private JSON-over-stdio bridge for MacLink's native firmware workflow."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / ".local"


def emit(message, kind="status", **extra):
    print(json.dumps(dict(kind=kind, message=message, **extra)), flush=True)


def fingerprint(spec):
    fields = {k: spec[k] for k in ("displayID", "serverURL", "deviceToken", "ssid", "password")}
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def validate(spec):
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", spec.get("displayID", "")):
        raise ValueError("Select a valid display.")
    if not isinstance(spec.get("ssid"), str) or not 1 <= len(spec["ssid"].encode()) <= 32:
        raise ValueError("Enter a Wi-Fi network name (up to 32 bytes).")
    password = spec.get("password")
    if not isinstance(password, str) or not (8 <= len(password.encode()) <= 63 or (len(password) == 64 and all(c in "0123456789abcdefABCDEF" for c in password))):
        raise ValueError("Enter an 8–63 character Wi-Fi password, or a 64-digit hexadecimal key.")
    if not spec.get("deviceToken") or not spec.get("serverURL", "").startswith(("http://", "https://")):
        raise ValueError("Connect and pair this display with the home server first.")


def check_partition(data, image_size):
    entries = []
    for offset in range(0, min(len(data), 0xC00), 32):
        entry = data[offset:offset+32]
        if len(entry) != 32 or entry[:2] != b"\xaa\x50":
            break
        _, kind, subtype, address, size, label, flags = struct.unpack("<HBBII16sI", entry)
        entries.append((kind, subtype, address, size, flags))
    apps = [e for e in entries if e[0] == 0]
    if len(apps) != 1 or apps[0][2:4] != (0x10000, 0x300000) or apps[0][4] != 0:
        raise ValueError("This device has an unsupported partition layout. Its flash was not changed.")
    if not 0 < image_size <= apps[0][3]:
        raise ValueError("The firmware does not fit the device's app partition.")


def main():
    spec = json.load(sys.stdin)
    action = spec.get("action")
    os.umask(0o077)
    LOCAL.mkdir(parents=True, exist_ok=True)
    # All GUI operations share the same toolchain; do not race another GUI process.
    with (LOCAL / "firmware-app.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another firmware operation is running. Wait for it to finish.")
        secrets = [str(spec.get(k, "")) for k in ("password", "deviceToken", "ssid")]

        def run(command, timeout=1800):
            # Keep verbose compiler output in memory, redact it before returning errors.
            result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, text=True)
            output = result.stdout
            for secret in secrets:
                if secret:
                    output = output.replace(secret, "[private]").replace(json.dumps(secret)[1:-1], "[private]")
            if result.returncode:
                emit(output[-5000:], "log")
                raise ValueError("The firmware tool failed. See Details below, correct the problem and try again.")
            return output

        python = LOCAL / "venv/bin/python"
        if action == "prepare":
            emit("Preparing the firmware tools. The first setup may take a few minutes.")
            uv = shutil.which("uv")
            if not uv:
                raise ValueError("Install uv on this Mac, then prepare the tools again.")
            if not python.exists():
                run([uv, "venv", str(LOCAL / "venv")])
            run([uv, "pip", "install", "--python", str(python), "platformio==6.2.0", "py-opendisplay==7.16.0", "pyserial==3.5", "esptool==5.4.0"])
            emit("Firmware tools are ready.", "done")
            return
        if not python.exists():
            raise ValueError("Prepare the firmware tools first.")
        validate(spec)
        display = spec["displayID"]
        image = LOCAL / "firmware" / ("maclink-" + display + ".bin")
        manifest = image.with_suffix(".json")
        if action == "build":
            device = LOCAL / ("device-" + display + ".json")
            wifi = LOCAL / ("wifi-build-" + display + ".json")
            device.write_text(json.dumps(dict(id=display, token=spec["deviceToken"], serverURL=spec["serverURL"])))
            device.chmod(0o600)
            wifi.write_text(json.dumps(dict(ssid=spec["ssid"], password=spec["password"])))
            wifi.chmod(0o600)
            manifest.unlink(missing_ok=True)
            emit("Building OpenDisplay with Wi-Fi and deep sleep. This can take several minutes.")
            try:
                run([str(python), "scripts/build-firmware.py", "--device", device.name, "--wifi", wifi.name, "--output", image.name, "--no-register"])
                digest = hashlib.sha256(image.read_bytes()).hexdigest()
                manifest.write_text(json.dumps(dict(displayID=display, fingerprint=fingerprint(spec), sha256=digest)))
            finally:
                wifi.unlink(missing_ok=True)
                # The compiled image necessarily contains credentials; remove transient source copies.
                (LOCAL / "vendor/opendisplay-firmware/src/maclink_secrets.h").unlink(missing_ok=True)
            emit("Firmware built. Connect the display and choose Flash over USB.", "done")
            return
        if action != "flash":
            raise ValueError("Unknown firmware operation.")
        if not image.exists() or not manifest.exists():
            raise ValueError("Build firmware for this display first.")
        saved = json.loads(manifest.read_text())
        if saved.get("displayID") != display or saved.get("fingerprint") != fingerprint(spec) or saved.get("sha256") != hashlib.sha256(image.read_bytes()).hexdigest():
            raise ValueError("Settings or the firmware image changed. Build again before flashing.")
        port = spec.get("port", "")
        if not re.fullmatch(r"/dev/cu\.(usbmodem|usbserial)[a-zA-Z0-9._-]+", port):
            raise ValueError("Choose the display's USB serial connection.")
        emit("Waiting for USB. A sleeping display may take up to five minutes to wake.")
        deadline = time.monotonic() + 330
        while not Path(port).exists():
            if time.monotonic() > deadline:
                raise ValueError("The display did not reconnect. Check the USB cable or press Reset, then try again.")
            time.sleep(0.05)
        emit("Checking the connected ESP32-C3 and its partition layout.")
        command = [str(python), "-m", "esptool", "--chip", "esp32c3", "--port", port, "--baud", "460800"]
        identity = run(command + ["--after", "no-reset", "read-mac"], 40)
        match = re.search(r"MAC(?: address)?:\s*([0-9a-fA-F:]{17})", identity)
        if not match:
            raise ValueError("Could not verify the connected device identity.")
        mac = match.group(1).lower()
        if saved.get("mac") and saved["mac"] != mac:
            raise ValueError("A different physical display is connected. Rebuild for the intended display first.")
        folder = LOCAL / "firmware/backups" / mac.replace(":", "")
        folder.mkdir(parents=True, exist_ok=True)
        partition = folder / "partitions.bin"
        run(command + ["--after", "no-reset", "read-flash", "0x8000", "0x1000", str(partition)], 60)
        check_partition(partition.read_bytes(), image.stat().st_size)
        backup = folder / "before-maclink.bin"
        checksum = backup.with_suffix(".sha256")
        if not backup.exists() or not checksum.exists() or checksum.read_text() != hashlib.sha256(backup.read_bytes()).hexdigest():
            emit("Backing up the device before flashing. Keep USB connected.")
            run(command + ["--after", "no-reset", "read-flash", "0", "0x400000", str(backup)], 180)
            if backup.stat().st_size != 0x400000:
                raise ValueError("The backup is incomplete. The device was not flashed.")
            checksum.write_text(hashlib.sha256(backup.read_bytes()).hexdigest())
        emit("Flashing and verifying the firmware. Keep USB connected until this finishes.")
        run(command + ["write-flash", "0x10000", str(image)], 120)
        saved["mac"] = mac
        manifest.write_text(json.dumps(saved))
        emit("Firmware flashed and verified. The display is restarting; check Preview for its server confirmation.", "done")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Deliberately avoid raw exception text that might contain request credentials.
        message = str(error) if isinstance(error, ValueError) else "The firmware operation could not finish. Check the tools and USB connection, then try again."
        emit(message, "error")
        sys.exit(1)
