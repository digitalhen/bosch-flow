"""Background poller: fetch fresh state, detect events, dispatch webhooks."""
from __future__ import annotations

import asyncio
import json
import time
from collections import deque
from pathlib import Path

import httpx

from . import config, events, notify, webhooks
from .bosch import BoschClient, BoschError
from .store import TokenStore

def _state_path() -> Path:
    return config.data_path(config.POLLER_STATE_FILE)


def _log_path() -> Path:
    return config.data_path(config.EVENTS_LOG_FILE)


# in-memory ring of recent events for GET /api/events
_RECENT: deque[dict] = deque(maxlen=config.EVENTS_LOG_MAX)


def _load_state() -> dict:
    p = _state_path()
    return json.loads(p.read_text()) if p.exists() else {}


def _save_state(state: dict) -> None:
    _state_path().write_text(json.dumps(state, indent=2))


def recent_events(limit: int = 50) -> list[dict]:
    return list(_RECENT)[-limit:][::-1]


def _log_event(rec: dict) -> None:
    _RECENT.append(rec)
    with _log_path().open("a") as f:
        f.write(json.dumps(rec) + "\n")


def _prime_recent() -> None:
    """Load the tail of the on-disk log into memory on startup."""
    log = _log_path()
    if not log.exists():
        return
    for line in log.read_text().splitlines()[-config.EVENTS_LOG_MAX:]:
        try:
            _RECENT.append(json.loads(line))
        except json.JSONDecodeError:
            pass


async def _snapshot(client: BoschClient, bike_id: str) -> dict:
    battery = await client.battery(bike_id)
    profile = await client.profile(bike_id)
    rides = await client.rides(bike_id)  # cheap: no gps enrichment
    return events.build_snapshot(battery, profile, rides)


async def poll_user(store: TokenStore, http: httpx.AsyncClient, user_id: str,
                    dispatch: bool = True) -> list[dict]:
    """One poll cycle for a user. Returns the events detected."""
    client = BoschClient(store, user_id, http, fresh=True)
    state = _load_state()
    fired: list[dict] = []
    deliveries: list[tuple[dict, dict]] = []  # (subscription, event record)
    for bike in await client.bikes():
        bike_id = bike["id"]
        bike_name = f"{bike.get('brand') or 'eBike'} {bike.get('drive_unit') or ''}".strip()
        key = f"{user_id}:{bike_id}"
        cur = await _snapshot(client, bike_id)
        prev = state.get(key)
        state[key] = cur
        if prev is None:
            continue  # first sighting: set a baseline, don't fire
        for ev in events.detect(prev, cur):
            rec = {
                "event": ev["event"],
                "bike_id": bike_id,
                "user": user_id,
                "at": time.time(),
                "data": ev["data"],
            }
            _log_event(rec)
            fired.append(rec)
            if dispatch:
                await notify.for_event(rec, bike_name)  # local desktop alert
                for sub in webhooks.subscribers_for(ev["event"]):
                    deliveries.append((sub, rec))
    _save_state(state)
    # fan out deliveries concurrently so one slow endpoint can't stall the rest
    if deliveries:
        results = await asyncio.gather(
            *(webhooks.deliver(http, sub, rec) for sub, rec in deliveries))
        for (sub, rec), result in zip(deliveries, results):
            _log_event({"event": "webhook.delivery", "at": time.time(),
                        "target": sub["id"], "of": rec["event"], "result": result})
    return fired


async def poll_once(store: TokenStore, http: httpx.AsyncClient,
                    dispatch: bool = True) -> list[dict]:
    fired: list[dict] = []
    for user_id in store.users():
        try:
            fired += await poll_user(store, http, user_id, dispatch)
        except BoschError as e:
            _log_event({"event": "poll.error", "user": user_id,
                        "at": time.time(), "detail": e.detail})
    return fired


async def run_loop(app) -> None:
    """Long-running background task started from the app lifespan."""
    _prime_recent()
    while True:
        try:
            await poll_once(app.state.store, app.state.http)
        except Exception as e:  # noqa: BLE001 - keep the loop alive
            _log_event({"event": "poll.crash", "at": time.time(), "detail": str(e)})
        await asyncio.sleep(config.POLL_INTERVAL)
