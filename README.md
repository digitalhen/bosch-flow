# bosch-flow

Get your **Bosch eBike Flow** data (Tern GSD and any Bosch Smart System bike with
a ConnectModule) out of Bosch's cloud and into:

- a **CLI** for quick pulls,
- a **local REST API** that normalizes Bosch's messy multi-host cloud,
- a **web dashboard** (battery, per-mode efficiency, ride map, GPX export),
- **event webhooks** (battery full/low, charging, ride completed, firmware…),
- a native **macOS menu bar app** with live status and desktop notifications.

> ⚠️ **Unofficial.** This talks to Bosch's private eBike Flow API using the mobile
> app's OAuth client (reverse-engineered). It is not endorsed by Bosch, may break
> if Bosch changes things, and is intended for personal use with **your own**
> account. See [Limitations](#limitations--caveats).

---

## Contents

1. [Requirements](#requirements)
2. [Setup](#1-setup)
3. [**Get a token (authenticate with Bosch)**](#2-get-a-token-authenticate-with-bosch) ← start here
4. [Run the API + dashboard](#3-run-the-api--dashboard)
5. [Menu bar app (macOS)](#4-menu-bar-app-macos)
6. [Events & webhooks](#5-events--webhooks)
7. [Configuration](#configuration)
8. [API reference](#api-reference)
9. [How it works](#how-it-works)
10. [Limitations & caveats](#limitations--caveats)
11. [Project layout](#project-layout)

---

## Requirements

- **Python 3.9+** (developed on 3.14)
- A **Bosch eBike** with a **ConnectModule** and an **eBike Flow** account
- **macOS** — only needed for the menu bar app + native notifications; the CLI,
  API, and dashboard run anywhere
- For the menu bar app: **Xcode command-line tools** (`swiftc`)

---

## 1. Setup

```bash
git clone <this repo> bosch-flow && cd bosch-flow
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt
```

That's it for the server. The CLI (`bosch_ebike_poc.py`) needs **no dependencies**
at all (pure standard library).

---

## 2. Get a token (authenticate with Bosch)

This is the only fiddly part. Bosch's OAuth client redirects to an **iOS app deep
link** (`onebikeapp-ios://…`) that a browser can't follow, so you have to grab the
authorization `code` out of the browser's developer tools by hand. You do this
**once**; after that the token auto-refreshes.

### Option A — CLI (simplest)

```bash
python3 bosch_ebike_poc.py login
```

It prints a long `https://p9.authz.bosch.com/…` URL. Then:

1. **Open that URL in a desktop browser** (Chrome or Firefox).
2. Open **DevTools → Network tab** *before* logging in, and enable
   **"Preserve log"** (Chrome) / **"Persist Logs"** (Firefox).
3. **Log in** with your **eBike Flow app credentials** (same as the phone app).
4. After login the page tries to redirect to
   `onebikeapp-ios://com.bosch.ebike.onebikeapp/oauth2redirect?code=…` and
   **fails** — that's expected (browsers can't open an iOS app link).
5. In the **Network tab**, find that **failed `onebikeapp-ios://…` request**.
   Copy the value of its **`code`** query parameter — a very long (500–1000+ char)
   string. (You can also copy the whole `onebikeapp-ios://…` URL; the tool will
   extract the code.)
6. **Paste it** back into the CLI prompt and press Enter.

The tokens are saved to **`bosch_tokens.json`**. Verify:

```bash
python3 bosch_ebike_poc.py bikes      # list your bike(s)
python3 bosch_ebike_poc.py fetch      # battery, range, odometer…
```

The API server **auto-imports `bosch_tokens.json`** on first run, so once the CLI
login works, the server and dashboard are authenticated too.

### Option B — via the API server

If you'd rather not use the CLI:

```bash
# 1) start the server (see section 3), then:
curl -s http://127.0.0.1:8099/api/auth/login
#    -> {"auth_url": "...", "state": "..."}
```

Do steps 1–5 above with the returned `auth_url`, then exchange the code:

```bash
curl -s -XPOST http://127.0.0.1:8099/api/auth/callback \
  -H 'content-type: application/json' \
  -d '{"code":"<PASTED_CODE_OR_URL>", "state":"<STATE_FROM_LOGIN>"}'
#    -> {"user": "<rider-id>", "bikes": [...]}
```

Tokens are stored in **`bosch_users.json`** (keyed by your Bosch rider id) and
**auto-refreshed** (the access token lasts ~2h; a refresh token is used silently).

### Where tokens live / resetting

| File | Written by | Contains |
|------|------------|----------|
| `bosch_tokens.json` | CLI `login` | single-user access + refresh token |
| `bosch_users.json`  | API `/auth/callback` | multi-user token store |

Delete these to log out. If a refresh ever fails (e.g. Bosch invalidated it),
just run `login` again.

---

## 3. Run the API + dashboard

```bash
./.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8099 --reload
```

Open **http://127.0.0.1:8099/** — the dashboard shows battery, range per assist
mode, lifetime mode efficiency, firmware inventory, a map of your rides, and GPX
downloads. Hit **⟳ Refresh** to force a fresh pull past the cache.

Click any ride to draw its **GPS track colored by metric** — toggle between
**Speed / Power / Cadence** (top-right of the map) to see where you were fast vs.
where you actually put power down. Deep-link straight to a ride with
`?ride=<activity-id>&metric=power_w`.

> Note: Bosch records the *assist mode* only as a whole-ride total (distance per
> mode), not per GPS point — so the track can be colored by speed/power/cadence,
> but not by which assist mode you were in at each point.

The server also starts a **background poller** (every 5 min) that powers events,
webhooks, and notifications.

---

## 4. Menu bar app (macOS)

A native menu bar app that shows live battery % and posts **native desktop
notifications** on events (this is the reliable way to get banners — a proper app
gets its own notification permission).

**Prebuilt:** a signed build is committed at **`menubar/dist/Bosch-Flow-1.0.zip`** —
just unzip and drag to `/Applications` (no Xcode needed). It's ad-hoc signed, so if
macOS says it's from an unidentified developer, right-click → **Open** once (or run
`xattr -cr "Bosch Flow.app"`).

**Or build it yourself:**

```bash
cd menubar
./build.sh                 # compiles + signs "Bosch Flow.app" (needs swiftc)
open "Bosch Flow.app"
```

On first launch macOS asks **"Bosch Flow" would like to send notifications** —
click **Allow** (this is what makes banners work). The app talks to the local API
at `http://127.0.0.1:8099`, so **keep the server (section 3) running**.

- Menu bar shows `🚲 100%` (⚡ when charging).
- Click it for a popover: battery, ranges, odometer, latest ride, **Dashboard**
  and **Refresh** buttons.
- New events (battery full, ride logged, …) fire native banners.

To have it start at login: System Settings → General → Login Items → add
`Bosch Flow.app`.

---

## 5. Events & webhooks

Bosch's API is **poll-only** (no push). The poller diffs each fresh snapshot and
emits edge-triggered events:

`battery.full` · `battery.low` · `battery.charging_started` ·
`battery.charging_stopped` · `charger.connected` · `charger.disconnected` ·
`ride.completed` · `firmware.changed`

Register an outbound webhook (fired with an HMAC signature):

```bash
curl -s -XPOST http://127.0.0.1:8099/api/webhooks \
  -H 'content-type: application/json' \
  -d '{"url":"https://example.com/hook","events":["battery.full","ride.completed"]}'
#   -> returns a "secret" ONCE; use it to verify signatures
```

Each delivery carries:

```
X-Bosch-Flow-Event: battery.full
X-Bosch-Flow-Signature: sha256=<hmac_sha256(secret, raw_body)>
```

Verify by recomputing the HMAC over the raw request body. See
[API reference](#api-reference) for `GET /api/events`, `POST /api/poll`, etc.

---

## Configuration

Edit `app/config.py`:

| Setting | Default | Meaning |
|---------|---------|---------|
| `POLL_INTERVAL` | `300` | seconds between poll cycles |
| `BATTERY_LOW_PCT` | `20` | threshold for `battery.low` |
| `TTL_LIVE` / `TTL_PROFILE` / `TTL_RIDES` | 300 / 900 / 600 | cache TTLs (s) |
| `NOTIFY_ENABLED` | `False` | fire `terminal-notifier` from the server (the menu bar app handles notifications instead) |
| `WEBHOOK_RETRIES` | `3` | delivery attempts w/ backoff |

The macOS notification sender identity is in `NOTIFY_SENDER` (only used when
`NOTIFY_ENABLED = True`).

---

## API reference

| Endpoint | Returns |
|----------|---------|
| `GET /api/bikes` | bikes on the account |
| `GET /api/bikes/{id}/battery` | live SoC, charging, range per mode, odometer |
| `GET /api/bikes/{id}/profile` | model, ABS/alarm, firmware inventory, health |
| `GET /api/bikes/{id}/stats` | per-mode lifetime distance + Wh/km |
| `GET /api/bikes/{id}/rides` | ride list (`?gps=1` adds `has_gps`/`gps_points`) |
| `GET /api/bikes/{id}/rides/{aid}` | ride summary + GPS time series |
| `GET /api/bikes/{id}/rides/{aid}.gpx` | ride as GPX |
| `GET /api/bikes/{id}/tracks.geojson` | all GPS tracks as one layer |
| `GET /api/bikes/{id}/location` | last-known position (newest GPS ride) |
| `GET /api/events?limit=50` | recent event log |
| `POST /api/poll` | run one poll cycle now (`?dispatch=0` = detect only) |
| `GET/POST /api/webhooks`, `DELETE /api/webhooks/{id}`, `POST /api/webhooks/{id}/test` | manage webhooks |
| `GET /api/auth/login`, `POST /api/auth/callback` | authentication |

Add `?fresh=1` to any data endpoint to bypass the cache. Select a user (multi-user
setups) with `X-Bike-User: <rider-id>` or `?user=`.

---

## How it works

Bosch splits data across several hosts under `*.prod.connected-biking.cloud`,
behind an OAuth2 + PKCE Keycloak (`p9.authz.bosch.com`, realm `obc`, client
`one-bike-app`). This project is a **facade** over that:

- **`app/auth.py`** — OAuth2 + PKCE (build URL, exchange code, refresh).
- **`app/bosch.py`** — async client that hides tokens, caches per Bosch's cadence,
  and **normalizes** the raw JSON. Data comes from `obc-rider-profile`
  (`/v1/bike-profile`, `/v1/state-of-charge`) and `obc-rider-activity`
  (`/v1/activity`, `/v1/activity/{id}/detail` — the source of GPS tracks).
- **`app/poller.py`** — background loop → snapshot diff → events → webhooks.

Live data (`state-of-charge`) is only fresh when the ConnectModule is **charging,
powered on, or alarmed**; otherwise you get last-known values.

---

## Limitations & caveats

- **Unofficial / ToS.** Uses the eBike Flow app's OAuth client. Fine for personal
  use with your own account; not a basis for a public multi-user product — that
  needs official [Bosch Connected Biking Platform](https://www.bosch-ebike.com/en/business/connected-biking-platform)
  partner API access (your own client + redirect URIs → a real one-click web login).
- **Login is manual.** The client only accepts the app's deep-link redirect URIs,
  so there's no hosted browser-redirect login — hence the DevTools code copy.
- **Location.** GPS tracks exist only for rides recorded with the phone. The app's
  live "where's my bike" pin (anti-theft) is served by a separate host whose exact
  route isn't mapped here.
- **Notifications are local** to whichever machine runs the menu bar app; use
  webhooks to reach elsewhere.
- **Sync lag.** Rides appear only after the bike syncs to Bosch's cloud (open the
  Flow app near the powered-on bike); the odometer updates independently and
  sooner.

---

## Project layout

```
bosch_ebike_poc.py      zero-dependency CLI (login / bikes / fetch / raw)
requirements.txt        server deps (starlette, uvicorn, httpx)
app/
  config.py             hosts, OAuth, cache TTLs, poller + notify settings
  auth.py               OAuth2 + PKCE helpers
  store.py              multi-user, file-backed token store
  bosch.py              async facade: raw endpoints + normalization + cache
  tracks.py             GPX / GeoJSON rendering
  events.py             pure event-detection rules (snapshot diff)
  webhooks.py           webhook subscriptions + signed delivery
  poller.py             background poll loop + event log
  notify.py             (optional) server-side macOS notifications
  main.py               Starlette routes + serves the dashboard
web/index.html          the dashboard (Leaflet map + cards)
menubar/
  BoschFlow.swift       menu bar app source
  makeicon.swift        app-icon generator
  build.sh              compile + bundle + sign "Bosch Flow.app"
```

Token / state files (git-ignored, created at runtime): `bosch_tokens.json`,
`bosch_users.json`, `bosch_webhooks.json`, `bosch_poller_state.json`,
`bosch_events.jsonl`.
