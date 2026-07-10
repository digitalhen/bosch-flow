"""OAuth2 + PKCE helpers for the Bosch eBike Flow identity service (async)."""
from __future__ import annotations

import base64
import hashlib
import secrets
from urllib.parse import urlencode

import httpx

from . import config


def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def pkce_pair() -> tuple[str, str]:
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def build_auth_url(code_challenge: str, state: str) -> str:
    params = {
        "client_id": config.CLIENT_ID,
        "redirect_uri": config.REDIRECT_URI,
        "response_type": "code",
        "scope": config.SCOPE,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "kc_idp_hint": "skid",
        "prompt": "login",
        "nonce": _b64url(secrets.token_bytes(32)),
        "state": state,
    }
    return f"{config.AUTH_URL}?{urlencode(params)}"


async def exchange_code(client: httpx.AsyncClient, code: str, verifier: str) -> dict:
    resp = await client.post(
        config.TOKEN_URL,
        data={
            "grant_type": "authorization_code",
            "client_id": config.CLIENT_ID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": config.REDIRECT_URI,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"},
    )
    resp.raise_for_status()
    return resp.json()


async def refresh_token(client: httpx.AsyncClient, refresh: str) -> dict:
    resp = await client.post(
        config.TOKEN_URL,
        data={
            "grant_type": "refresh_token",
            "client_id": config.CLIENT_ID,
            "refresh_token": refresh,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"},
    )
    resp.raise_for_status()
    return resp.json()
