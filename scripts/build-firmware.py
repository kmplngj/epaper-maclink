# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Jan Kampling
# OpenDisplay integration and patches; see ../firmware/LICENSE.

"""Build the pinned OpenDisplay release plus MacLink's streaming HTTP transport.

Run with .local/venv/bin/python (platformio + py-opendisplay installed).
Credentials and binaries stay under ignored .local/. This command never flashes.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request
from opendisplay.models.config import GlobalConfig, SystemConfig, ManufacturerData, PowerOption, DisplayConfig
from opendisplay.protocol.config_serializer import serialize_config

root = Path(__file__).resolve().parents[1]
local = root / ".local"
vendor = local / "vendor/opendisplay-firmware"
revision = "7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb"
parser = argparse.ArgumentParser()
parser.add_argument("--debug-awake", action="store_true")
parser.add_argument("--compile-only", action="store_true", help="Allow placeholder Wi-Fi credentials, for compile validation only")
parser.add_argument("--usb-panel-test", type=Path, help="Offline hardware diagnostic: embed this private 800x480 PNG and test panel + timer wake, without Wi-Fi")
parser.add_argument("--device", default="device.json", help="Private device configuration filename under .local")
parser.add_argument("--wifi", default="wifi.json", help="Private Wi-Fi configuration filename under .local")
parser.add_argument("--output", help="Output filename under .local/firmware")
parser.add_argument("--no-register", action="store_true", help="Require an existing display configuration")
args = parser.parse_args()
local.mkdir(parents=True,exist_ok=True)
os.umask(0o077)
build_lock=(local/"firmware-build.lock").open("w")
try: fcntl.flock(build_lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
except BlockingIOError: sys.exit("Another firmware build is already running. Wait for it to finish.")
for name in [args.device,args.wifi,args.output]:
    if name is not None and (Path(name).name!=name or name in (".","..")):
        sys.exit("Configuration and output names must be filenames, not paths.")
if not vendor.exists():
    subprocess.run(["git", "clone", "--branch", "2.26.5", "--depth", "1", "https://github.com/OpenDisplay/Firmware.git", str(vendor)], check=True)
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=vendor).decode().strip() == revision, "Unexpected upstream revision"

device_path = local / args.device
if device_path.exists():
    device = json.loads(device_path.read_text())
else:
    if args.no_register: sys.exit("Pair the selected display before building its firmware.")
    server = json.loads((local / "server.json").read_text())
    req = urllib.request.Request(server["serverURL"] + "/v1/displays", data=json.dumps({"name": "Desk", "width":800, "height":480, "poll_seconds":300}).encode(), headers={"Authorization":"Bearer " + server["token"], "Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=10) as response:
        result=json.load(response)
    device={"id": result["display"]["id"], "token": result["device_token"], "serverURL":server["serverURL"]}
    device_path.write_text(json.dumps(device)); device_path.chmod(0o600)
wifi_path=local / args.wifi
if wifi_path.exists():
    wifi=json.loads(wifi_path.read_text()); wifi_path.chmod(0o600)
elif args.compile_only or args.usb_panel_test:
    wifi={"ssid":"MACLINK-NOT-PROVISIONED", "password":""}
else:
    sys.exit("Create .local/wifi.json with ssid and password before building deployable firmware.")
if not args.compile_only and not args.usb_panel_test:
    if not isinstance(wifi.get("ssid"),str) or not 1<=len(wifi["ssid"].encode())<=32 or not isinstance(wifi.get("password"),str):
        sys.exit("Enter a valid Wi-Fi network name and password.")

for name in ("maclink_pull.h", "maclink_pull.cpp", "maclink_panel.inc", "maclink_schedule.h"):
    shutil.copyfile(root/"firmware"/name, vendor/"src"/name)
main=vendor/"src/main.cpp"
source=main.read_text()
if '#include "maclink_pull.h"' not in source:
    source='#ifdef MACLINK_HTTP_PULL\n#include "maclink_pull.h"\n#endif\n'+source
    source=source.replace('    odWatchdogArm();\n', '    odWatchdogArm();\n#ifdef MACLINK_HTTP_PULL\n    maclinkPullRun();\n#endif\n',1)
    main.write_text(source)
panel=vendor/"src/display_service.cpp"
if '#include "maclink_panel.inc"' not in panel.read_text():
    with panel.open("a") as f: f.write('\n#ifdef MACLINK_HTTP_PULL\n#include "maclink_panel.inc"\n#endif\n')
values={"MACLINK_URL":device["serverURL"].rstrip("/")+"/v1/displays/"+device["id"],"MACLINK_TOKEN":device["token"],"MACLINK_SSID":wifi["ssid"],"MACLINK_PASSWORD":wifi["password"]}
secret=vendor/"src/maclink_secrets.h"
secret.write_text("#pragma once\n"+"\n".join(f"#define {key} {json.dumps(value,ensure_ascii=True)}" for key,value in values.items())+"\n")
secret.chmod(0o600)

# Official OpenDisplay simple-config preset: xiao-75-c3 + ep75-800x480.
config=GlobalConfig(
    system=SystemConfig(ic_type=3,communication_modes=1,device_flags=0,pwr_pin=255,reserved=bytes(15)),
    manufacturer=ManufacturerData(manufacturer_id=1,board_type=4,board_revision=1,reserved=bytes(6),simple_config_driver_index=12,simple_config_display_index=14),
    power=PowerOption(power_mode=1,battery_capacity_mah=bytes(3),sleep_timeout_ms=1000,tx_power=0,sleep_flags=0,battery_sense_pin=255,battery_sense_enable_pin=255,battery_sense_flags=0,capacity_estimator=0,voltage_scaling_factor=1000,deep_sleep_current_ua=0,deep_sleep_time_seconds=300,charge_enable_pin=255,charge_state_pin=255,charger_flags=0,min_wake_time_seconds=1,screen_timeout_seconds=0,reserved=bytes(4)),
    displays=[DisplayConfig(instance_number=0,display_technology=0,panel_ic_type=59,pixel_width=800,pixel_height=480,active_width_mm=163,active_height_mm=98,tag_type=0,rotation=0,reset_pin=2,busy_pin=4,dc_pin=5,cs_pin=3,data_pin=10,partial_update_support=2,color_scheme=0,transmission_modes=0x25,clk_pin=8,reserved_pins=bytes([255]*7),full_update_mC=42,reserved=bytes(13))],
    version=1,
)
flags=["BUILD_VERSION=2.26.5","SHA=7c9413edd9f7fa16e714f6ebc00b76efd3bad4eb","TARGET_ESP32","OPENDISPLAY_ZLIB_USE_HEAP_WINDOW=1","ARDUINO_USB_MODE=1","ARDUINO_USB_CDC_ON_BOOT=1","CONFIG_FREERTOS_WATCHDOG_TIMEOUT_S=120","MACLINK_HTTP_PULL"]
if args.debug_awake: flags.append("MACLINK_DEBUG_AWAKE")
if args.usb_panel_test:
    from PIL import Image
    with Image.open(args.usb_panel_test) as image:
        assert image.size==(800,480), "The panel test requires an 800x480 image"
        pixels=image.convert("L").point(lambda v:255 if v>=128 else 0,mode="1").tobytes()
    digest=hashlib.sha256(b"mono1:white=1:msb:800:480:"+pixels).hexdigest()
    fixture=vendor/"src/maclink_panel_test.h"
    fixture.write_text('#pragma once\n#define MACLINK_TEST_HASH "'+digest+'"\nstatic const unsigned char maclinkTestPixels[48000] = {'+','.join(str(v) for v in pixels)+'};\n')
    fixture.chmod(0o600)
    flags.append("MACLINK_USB_PANEL_TEST")
(vendor/"platformio.local.ini").write_text("[env:esp32-c3-N4]\nbuild_flags =\n"+"\n".join("  -D"+v for v in flags)+"\n")
packet=bytearray(serialize_config(config))
packet[0:2]=len(packet).to_bytes(2, "little")
sys.path.insert(0,str(vendor/"tools"))
from config_packet import validate_packet
validate_packet(bytes(packet))
env=os.environ.copy();env["OPENDISPLAY_FACTORY_CONFIG_HEX"]=packet.hex()
subprocess.run([sys.executable,"-m","platformio","run","-e","esp32-c3-N4"],cwd=vendor,env=env,check=True)
output=local/"firmware"/(args.output or ("maclink-c3-usb-test.bin" if args.usb_panel_test else "maclink-c3-app.bin"))
output.parent.mkdir(parents=True,exist_ok=True)
shutil.copyfile(vendor/".pio/build/esp32-c3-N4/firmware.bin",output);output.chmod(0o600)
print("Built private app image:",output)
if args.compile_only and not wifi_path.exists(): print("COMPILE VALIDATION ONLY: Wi-Fi credentials were not provisioned.")
if args.usb_panel_test: print("USB DIAGNOSTIC ONLY: panel/RTC timer test; no network downloads or acknowledgements.")
