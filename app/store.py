"""Multi-user token store + PKCE login state (file-backed).

One process, one JSON file. Keyed by user id (the Bosch ebike-rider-id, derived
from the token). Single-user today; ready for many users when deployed.
"""
from __future__ import annotations

import base64
import json
import threading
import time
from pathlib import Path
from typing import Any

from . import config

_ROOT = Path(__file__).resolve().parent.parent
_LOCK = threading.Lock()


def _b64json(seg: str) -> dict:
    seg += "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))


def jwt_claims(access_token: str) -> dict:
    """Decode a JWT payload without verifying the signature (read-only use)."""
    try:
        return _b64json(access_token.split(".")[1])
    except Exception:
        return {}


def user_id_for(access_token: str) -> str:
    claims = jwt_claims(access_token)
    return claims.get("ebike-rider-id") or claims.get("sub") or "default"


class TokenStore:
    """Persists {user_id: token_record} and transient PKCE verifiers."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (_ROOT / config.USERS_FILE)
        self._pending: dict[str, str] = {}  # state -> code_verifier (login flow)
        self._migrate_legacy()

    # --- persistence --------------------------------------------------------
    def _read(self) -> dict[str, Any]:
        if not self.path.exists():
            return {}
        return json.loads(self.path.read_text())

    def _write(self, data: dict[str, Any]) -> None:
        self.path.write_text(json.dumps(data, indent=2))

    def _migrate_legacy(self) -> None:
        """Import a single-user bosch_tokens.json from the CLI POC, once."""
        if self.path.exists():
            return
        legacy = _ROOT / config.LEGACY_TOKEN_FILE
        if not legacy.exists():
            return
        rec = json.loads(legacy.read_text())
        uid = user_id_for(rec.get("access_token", ""))
        self._write({uid: rec})

    # --- token records ------------------------------------------------------
    def get(self, user_id: str) -> dict | None:
        return self._read().get(user_id)

    def put(self, tokens: dict) -> str:
        """Store a token response, keyed by its rider id. Returns the user id."""
        uid = user_id_for(tokens["access_token"])
        rec = dict(tokens)
        rec["expires_at"] = time.time() + rec.get("expires_in", 7200)
        with _LOCK:
            data = self._read()
            data[uid] = rec
            self._write(data)
        return uid

    def update(self, user_id: str, tokens: dict) -> None:
        rec = dict(tokens)
        rec["expires_at"] = time.time() + rec.get("expires_in", 7200)
        with _LOCK:
            data = self._read()
            # keep prior refresh_token if the refresh response omitted it
            if "refresh_token" not in rec and user_id in data:
                rec["refresh_token"] = data[user_id].get("refresh_token")
            data[user_id] = rec
            self._write(data)

    def users(self) -> list[str]:
        return list(self._read().keys())

    def default_user(self) -> str | None:
        users = self.users()
        return users[0] if len(users) >= 1 else None

    # --- PKCE login state ---------------------------------------------------
    def stash_verifier(self, state: str, verifier: str) -> None:
        self._pending[state] = verifier

    def pop_verifier(self, state: str) -> str | None:
        return self._pending.pop(state, None)
