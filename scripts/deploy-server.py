"""Deploy only this project's service; keep credentials out of command arguments/logs."""
import argparse
import ipaddress
import json
from pathlib import Path
import secrets
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--host", required=True, help="SSH host or configured alias")
parser.add_argument("--address", required=True, type=ipaddress.IPv4Address, help="Server LAN IPv4 address")
args = parser.parse_args()
if args.host.startswith("-") or any(character.isspace() for character in args.host):
    parser.error("--host must be an SSH host or alias, without options or whitespace")
local = root / ".local"
local.mkdir(exist_ok=True)
credential = local / "server.json"
if credential.exists():
    config = json.loads(credential.read_text())
else:
    config = {"serverURL": f"http://{args.address}:8099", "token": secrets.token_urlsafe(48)}
config["serverURL"] = f"http://{args.address}:8099"
credential.touch(mode=0o600, exist_ok=True)
credential.chmod(0o600)
credential.write_text(json.dumps(config))
subprocess.run(["ssh", args.host, "sudo -n mkdir -p /srv/epaper-maclink && sudo -n chown $(id -u):$(id -g) /srv/epaper-maclink"], check=True)
subprocess.run(["rsync", "-az", "--exclude=.venv", "--exclude=__pycache__", "--exclude=.pytest_cache", str(root / "server"), str(root / "compose.yaml"), args.host + ":/srv/epaper-maclink/"], check=True)
env = f"MACLINK_ADMIN_TOKEN={config['token']}\nMACLINK_BIND_ADDRESS={args.address}\n"
subprocess.run(["ssh", args.host, "umask 077; cat > /srv/epaper-maclink/.env"], input=env.encode(), check=True)
subprocess.run(["ssh", args.host, "cd /srv/epaper-maclink && docker compose up --build -d --wait"], check=True)
support = Path.home() / "Library/Application Support/MacLink"
support.mkdir(parents=True, exist_ok=True)
bootstrap = support / "bootstrap.json"
bootstrap.write_text(json.dumps(config))
bootstrap.chmod(0o600)
print("Service deployed; private Mac bootstrap saved.")
