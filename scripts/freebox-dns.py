#!/usr/bin/env python3
"""Point the Freebox (Pop/Delta/...) LAN DHCP at a custom DNS server.

On a Freebox network the box is the DHCP server, so the cleanest way to make
*every* device use Pi-hole is to set the DHCP-advertised DNS to the Pi-hole
LoadBalancer IP. This script does that via the Freebox OS API.

First run pairs the app — you must press the RIGHT ARROW on the Freebox front
panel to authorize it (one time). The app token is then cached next to this
script so subsequent runs are non-interactive.

Examples:
    python3 scripts/freebox-dns.py --show
    python3 scripts/freebox-dns.py --dns 192.168.1.42
    python3 scripts/freebox-dns.py --revert        # back to the Freebox itself

Only the Python standard library is used (no pip install).
"""
import argparse
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

APP_ID = "pi.aladhan.dns"
APP_NAME = "Aladhan DNS Setup"
APP_VERSION = "1.0.0"
DEVICE_NAME = "k8s-project"
DEFAULT_HOST = "http://mafreebox.freebox.fr"
API = "/api/v8"
TOKEN_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".fbx_token.json")


def _request(method, url, payload=None, headers=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        # The Freebox returns JSON error bodies even on 4xx.
        try:
            return json.loads(exc.read().decode())
        except Exception:
            raise


def load_token():
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as fh:
            return json.load(fh).get("app_token")
    return None


def save_token(token):
    with open(TOKEN_FILE, "w") as fh:
        json.dump({"app_token": token}, fh)
    os.chmod(TOKEN_FILE, 0o600)


def register(host):
    print(">> Pairing with the Freebox. Press the RIGHT ARROW on the Freebox "
          "front panel to authorize 'Aladhan DNS Setup'...", flush=True)
    res = _request("POST", f"{host}{API}/login/authorize/", {
        "app_id": APP_ID, "app_name": APP_NAME,
        "app_version": APP_VERSION, "device_name": DEVICE_NAME,
        "permissions": {"settings": True},
    }).get("result", {})
    app_token, track_id = res.get("app_token"), res.get("track_id")

    deadline = time.time() + 60
    while time.time() < deadline:
        status = _request("GET", f"{host}{API}/login/authorize/{track_id}").get("result", {}).get("status")
        if status == "granted":
            save_token(app_token)
            print(">> Authorized. Token cached.")
            return app_token
        if status in ("denied", "timeout"):
            sys.exit(f"Pairing {status}.")
        time.sleep(1)
    sys.exit("Pairing timed out (button not pressed in time).")


def login(host):
    token = load_token() or register(host)
    challenge = _request("GET", f"{host}{API}/login/").get("result", {}).get("challenge")
    if not challenge:
        sys.exit("Could not get a login challenge from the Freebox.")
    password = hmac.new(token.encode(), challenge.encode(), hashlib.sha1).hexdigest()
    res = _request("POST", f"{host}{API}/login/session/", {"app_id": APP_ID, "password": password})
    if not res.get("success"):
        if res.get("error_code") == "invalid_token":
            os.remove(TOKEN_FILE)
            sys.exit("Saved token is invalid — re-run to pair again.")
        sys.exit(f"Login failed: {res.get('msg')}")
    return {"X-Fbx-App-Auth": res["result"]["session_token"]}


def get_dhcp(host, headers):
    return _request("GET", f"{host}{API}/dhcp/config/", headers=headers).get("result", {})


def set_dhcp_dns(host, headers, dns_list):
    res = _request("PUT", f"{host}{API}/dhcp/config/", {"dns": dns_list}, headers=headers)
    if not res.get("success"):
        sys.exit(f"Failed to update DHCP DNS: {res.get('msg')}")
    return res.get("result", {})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default=DEFAULT_HOST, help="Freebox base URL")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dns", help="DNS IP to advertise via DHCP (e.g. the Pi-hole IP)")
    group.add_argument("--show", action="store_true", help="Show the current DHCP DNS and exit")
    group.add_argument("--revert", action="store_true", help="Clear custom DNS (use the Freebox itself)")
    args = parser.parse_args()

    headers = login(args.host)
    current = get_dhcp(args.host, headers)
    print(f"Current DHCP DNS: {current.get('dns')}")

    if args.show:
        return
    new_dns = [] if args.revert else [args.dns]
    result = set_dhcp_dns(args.host, headers, new_dns)
    print(f"Updated DHCP DNS: {result.get('dns')}")
    print("Devices will pick up the new DNS on their next DHCP lease renewal "
          "(reconnect Wi-Fi or reboot to apply immediately).")


if __name__ == "__main__":
    main()
