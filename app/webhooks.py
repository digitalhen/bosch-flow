"""Outbound webhook subscriptions + signed delivery."""
from __future__ import annotations

import hashlib
import hmac
import json
import time
import uuid
from pathlib import Path

import httpx

from . import config

def _path() -> Path:
    return config.data_path(config.WEBHOOKS_FILE)


def _read() -> list[dict]:
    p = _path()
    return json.loads(p.read_text()) if p.exists() else []


def _write(subs: list[dict]) -> None:
    _path().write_text(json.dumps(subs, indent=2))


def list_subs() -> list[dict]:
    # never leak secrets to API callers
    return [{k: v for k, v in s.items() if k != "secret"} for s in _read()]


def add_sub(url: str, events: list[str] | None, secret: str | None) -> dict:
    sub = {
        "id": uuid.uuid4().hex[:12],
        "url": url,
        "events": events or ["*"],
        "secret": secret or uuid.uuid4().hex,
        "created": time.time(),
        "active": True,
    }
    subs = _read()
    subs.append(sub)
    _write(subs)
    # the secret is returned ONCE, on creation, so the caller can verify sigs
    return sub


def delete_sub(sub_id: str) -> bool:
    subs = _read()
    kept = [s for s in subs if s["id"] != sub_id]
    if len(kept) == len(subs):
        return False
    _write(kept)
    return True


def get_sub(sub_id: str) -> dict | None:
    return next((s for s in _read() if s["id"] == sub_id), None)


def _matches(sub: dict, event: str) -> bool:
    if not sub.get("active"):
        return False
    subs = sub.get("events") or ["*"]
    return "*" in subs or event in subs


def subscribers_for(event: str) -> list[dict]:
    return [s for s in _read() if _matches(s, event)]


def _sign(secret: str, body: bytes) -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


async def deliver(http: httpx.AsyncClient, sub: dict, payload: dict) -> dict:
    """POST payload to a subscriber with HMAC signature + retry/backoff."""
    body = json.dumps(payload).encode()
    headers = {
        "Content-Type": "application/json",
        "X-Bosch-Flow-Event": payload.get("event", ""),
        "X-Bosch-Flow-Signature": _sign(sub["secret"], body),
        "User-Agent": "bosch-flow-webhook/1",
    }
    last = ""
    for attempt in range(config.WEBHOOK_RETRIES):
        try:
            r = await http.post(sub["url"], content=body, headers=headers,
                                 timeout=config.WEBHOOK_TIMEOUT)
            if r.status_code < 300:
                return {"ok": True, "status": r.status_code, "attempts": attempt + 1}
            last = f"HTTP {r.status_code}"
        except Exception as e:  # noqa: BLE001 - report any delivery failure
            last = type(e).__name__
        await _backoff(attempt)
    return {"ok": False, "error": last, "attempts": config.WEBHOOK_RETRIES}


async def _backoff(attempt: int) -> None:
    import asyncio
    await asyncio.sleep(min(2 ** attempt, 8))
