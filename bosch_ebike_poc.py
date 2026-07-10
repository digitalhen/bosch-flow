#!/usr/bin/env python3
"""
Bosch eBike Flow — data POC (standalone, zero dependencies).

Talks to the (reverse-engineered) Bosch eBike Flow cloud API to pull battery
and bike data for a Tern GSD / Bosch-powered ebike that has a ConnectModule.

Ported from Phil-Barker/hass-bosch-ebike (a Home Assistant integration) into a
single stdlib-only script so it runs anywhere Python 3.9+ is installed.

Usage:
    python3 bosch_ebike_poc.py login     # one-time: browser login -> paste code
    python3 bosch_ebike_poc.py bikes     # list bikes on the account
    python3 bosch_ebike_poc.py fetch     # pull battery/bike data (default bike)
    python3 bosch_ebike_poc.py raw       # dump raw JSON from both endpoints

Tokens are cached in ./bosch_tokens.json next to this script.
"""
from __future__ import annotations

import base64
import hashlib
import json
import secrets
import sys
import time
from pathlib import Path
from urllib import request, parse, error

# --- Constants (from the HA integration's const.py) -------------------------
AUTH_URL = "https://p9.authz.bosch.com/auth/realms/obc/protocol/openid-connect/auth"
TOKEN_URL = "https://p9.authz.bosch.com/auth/realms/obc/protocol/openid-connect/token"
API_BASE_URL = "https://obc-rider-profile.prod.connected-biking.cloud"

CLIENT_ID = "one-bike-app"
REDIRECT_URI = "onebikeapp-ios://com.bosch.ebike.onebikeapp/oauth2redirect"
SCOPE = "openid offline_access"

ENDPOINT_BIKE_PROFILE = "/v1/bike-profile"
ENDPOINT_STATE_OF_CHARGE = "/v1/state-of-charge"

TOKEN_FILE = Path(__file__).with_name("bosch_tokens.json")


# --- Tiny HTTP helpers (stdlib only) ----------------------------------------
def _http(method: str, url: str, *, headers=None, data=None, form=False):
    """Return (status, parsed_json_or_text). Never raises on HTTP status."""
    headers = dict(headers or {})
    body = None
    if data is not None:
        if form:
            body = parse.urlencode(data).encode()
            headers.setdefault(
                "Content-Type", "application/x-www-form-urlencoded; charset=UTF-8"
            )
        else:
            body = json.dumps(data).encode()
            headers.setdefault("Content-Type", "application/json")
    req = request.Request(url, method=method, headers=headers, data=body)
    try:
        with request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
    except error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        status = e.code
    except error.URLError as e:
        raise SystemExit(f"Network error contacting {url}: {e}")
    try:
        return status, json.loads(raw)
    except json.JSONDecodeError:
        return status, raw


# --- PKCE + OAuth -----------------------------------------------------------
def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def generate_pkce_pair() -> tuple[str, str]:
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def build_auth_url(code_challenge: str) -> str:
    params = {
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "scope": SCOPE,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "kc_idp_hint": "skid",
        "prompt": "login",
        "nonce": _b64url(secrets.token_bytes(32)),
        "state": _b64url(secrets.token_bytes(32)),
    }
    return f"{AUTH_URL}?{parse.urlencode(params)}"


def load_tokens() -> dict:
    if not TOKEN_FILE.exists():
        raise SystemExit("No tokens found. Run:  python3 bosch_ebike_poc.py login")
    return json.loads(TOKEN_FILE.read_text())


def save_tokens(tok: dict) -> None:
    tok = dict(tok)
    tok["expires_at"] = time.time() + tok.get("expires_in", 7200)
    TOKEN_FILE.write_text(json.dumps(tok, indent=2))
    print(f"  tokens saved -> {TOKEN_FILE}")


def refresh_if_needed(tok: dict) -> dict:
    """Refresh the access token if it expires within 10 minutes."""
    if tok.get("expires_at", 0) - time.time() > 600:
        return tok
    print("  access token expiring/expired -> refreshing...")
    status, resp = _http(
        "POST", TOKEN_URL, form=True,
        data={
            "grant_type": "refresh_token",
            "client_id": CLIENT_ID,
            "refresh_token": tok["refresh_token"],
        },
    )
    if status != 200:
        raise SystemExit(f"Token refresh failed ({status}): {resp}\n"
                         "Re-run 'login' to re-authenticate.")
    resp.setdefault("refresh_token", tok["refresh_token"])
    save_tokens(resp)
    return load_tokens()


# --- Authenticated API request ----------------------------------------------
def api_get(tok: dict, endpoint: str):
    tok = refresh_if_needed(tok)
    status, resp = _http(
        "GET", f"{API_BASE_URL}{endpoint}",
        headers={"Authorization": f"Bearer {tok['access_token']}"},
    )
    if status == 404:
        return None  # e.g. state-of-charge when bike is offline
    if status != 200:
        raise SystemExit(f"API {endpoint} failed ({status}): {resp}")
    return resp


# --- Commands ---------------------------------------------------------------
def cmd_login():
    verifier, challenge = generate_pkce_pair()
    auth_url = build_auth_url(challenge)
    print("\n=== Bosch eBike Flow login ===\n")
    print("1. Open this URL in a DESKTOP browser (Chrome/Firefox) with DevTools")
    print("   Network tab OPEN and 'Preserve log' ENABLED:\n")
    print(auth_url + "\n")
    print("2. Log in with your Bosch eBike Flow app credentials.")
    print("3. The page will fail to redirect to 'onebikeapp-ios://...' — that's")
    print("   expected. In the Network tab, find that failed request and copy")
    print("   the value of its 'code=' query parameter (a very long string).")
    print("   You can paste either the raw code OR the whole redirect URL.\n")
    entered = input("Paste code (or full redirect URL) here: ").strip()

    code = entered
    if "code=" in entered:
        qs = parse.parse_qs(parse.urlparse(entered).query)
        if "code" in qs:
            code = qs["code"][0]

    print("\nExchanging authorization code for tokens...")
    status, resp = _http(
        "POST", TOKEN_URL, form=True,
        data={
            "grant_type": "authorization_code",
            "client_id": CLIENT_ID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": REDIRECT_URI,
        },
    )
    if status != 200:
        raise SystemExit(f"Token exchange failed ({status}): {resp}")
    save_tokens(resp)
    print("\nLogin OK. Now try:  python3 bosch_ebike_poc.py fetch\n")


def get_bikes(tok: dict) -> list[dict]:
    resp = api_get(tok, ENDPOINT_BIKE_PROFILE)
    return (resp or {}).get("data", []) if resp else []


def cmd_bikes():
    tok = load_tokens()
    bikes = get_bikes(tok)
    if not bikes:
        print("No bikes found on this account.")
        return
    print(f"\nFound {len(bikes)} bike(s):\n")
    for b in bikes:
        attrs = b.get("attributes", {})
        du = attrs.get("driveUnit") or {}
        print(f"  id={b.get('id')}")
        print(f"    brand : {attrs.get('brandName')}")
        print(f"    drive : {du.get('productName')}")
        print(f"    frame : {attrs.get('frameNumber')}\n")


def _first_bike_id(tok: dict) -> str:
    bikes = get_bikes(tok)
    if not bikes:
        raise SystemExit("No bikes found on this account.")
    return bikes[0]["id"]


def cmd_fetch():
    tok = load_tokens()
    bike_id = sys.argv[2] if len(sys.argv) > 2 else _first_bike_id(tok)

    profile = api_get(tok, f"{ENDPOINT_BIKE_PROFILE}/{bike_id}")
    soc = api_get(tok, f"{ENDPOINT_STATE_OF_CHARGE}/{bike_id}")

    attrs = (profile or {}).get("data", {}).get("attributes", {})
    bats = attrs.get("batteries") or [{}]
    bat = bats[0] if bats else {}
    du = attrs.get("driveUnit") or {}

    def km(m):
        return f"{m/1000:.1f} km" if isinstance(m, (int, float)) else "—"

    print(f"\n=== {attrs.get('brandName', 'eBike')} — {du.get('productName', '')} ===")
    print(f"bike id: {bike_id}")
    print(f"live data (ConnectModule online): {'yes' if soc else 'no (offline — showing last-known)'}\n")

    lvl = (soc or {}).get("stateOfCharge", bat.get("batteryLevel"))
    charging = (soc or {}).get("chargingActive", bat.get("isCharging"))
    plugged = (soc or {}).get("chargerConnected", bat.get("isChargerConnected"))
    odo = (soc or {}).get("odometer", du.get("totalDistanceTraveled"))

    print("Battery")
    print(f"  level              : {lvl}%" if lvl is not None else "  level              : —")
    print(f"  remaining energy   : {bat.get('remainingEnergy')} Wh")
    print(f"  total capacity     : {bat.get('totalEnergy')} Wh")
    print(f"  charging           : {charging}")
    print(f"  charger connected  : {plugged}")
    print(f"  full charge cycles : {(bat.get('numberOfFullChargeCycles') or {}).get('total')}")
    print(f"  lifetime delivered : {bat.get('deliveredWhOverLifetime')} Wh")
    print("\nBike")
    print(f"  odometer           : {km(odo)}")
    print(f"  locked             : {(du.get('lock') or {}).get('isLocked')}")
    if soc:
        print(f"  reachable range    : {soc.get('reachableRange')}")
        print(f"  last update        : {soc.get('stateOfChargeLatestUpdate')}")
    print()


def cmd_raw():
    tok = load_tokens()
    bike_id = sys.argv[2] if len(sys.argv) > 2 else _first_bike_id(tok)
    out = {
        "bike-profile/{id}": api_get(tok, f"{ENDPOINT_BIKE_PROFILE}/{bike_id}"),
        "state-of-charge/{id}": api_get(tok, f"{ENDPOINT_STATE_OF_CHARGE}/{bike_id}"),
    }
    print(json.dumps(out, indent=2))


COMMANDS = {
    "login": cmd_login,
    "bikes": cmd_bikes,
    "fetch": cmd_fetch,
    "raw": cmd_raw,
}


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    fn = COMMANDS.get(cmd)
    if not fn:
        print(__doc__)
        raise SystemExit(1)
    fn()


if __name__ == "__main__":
    main()
