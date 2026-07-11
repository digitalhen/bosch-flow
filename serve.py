"""Entry point for the bundled backend.

Run directly (`python serve.py`) or as the frozen binary the menu bar app spawns.
Honors env vars so the .app can point it at a writable data dir and a chosen port:

    BOSCH_FLOW_DATA_DIR   where token/state/event files live (default: repo root)
    BOSCH_FLOW_HOST       bind host (default: 127.0.0.1)
    BOSCH_FLOW_PORT       bind port (default: 8099)
"""
from __future__ import annotations

import os

import uvicorn


def main() -> None:
    host = os.environ.get("BOSCH_FLOW_HOST", "127.0.0.1")
    port = int(os.environ.get("BOSCH_FLOW_PORT", "8099"))
    # Import the app object directly (not the "app.main:app" import string) so a
    # frozen/one-file build resolves it without a reload-capable import path.
    from app.main import app
    uvicorn.run(app, host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()
