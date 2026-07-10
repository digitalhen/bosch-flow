"""Native macOS Notification Center alerts for bike events (zero-dependency)."""
from __future__ import annotations

import asyncio
import shutil
import sys

from . import config

# terminal-notifier renders as a real (native) notification via a signed app
# bundle; -sender borrows a real app's icon/identity. Fall back to osascript.
_TN = shutil.which("terminal-notifier")


def _lit(s: str) -> str:
    """Quote a Python string as an AppleScript string literal."""
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


async def _run(*args: str) -> None:
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await proc.wait()
    except Exception:  # never let a notification failure break the poll loop
        pass


async def send(title: str, message: str, subtitle: str | None = None,
               sound: str | None = "Glass") -> None:
    if not config.NOTIFY_ENABLED or sys.platform != "darwin":
        return
    if _TN:
        args = [_TN, "-title", title, "-message", message, "-sender", config.NOTIFY_SENDER]
        if subtitle:
            args += ["-subtitle", subtitle]
        if sound:
            args += ["-sound", sound]
        await _run(*args)
        return
    # fallback: osascript (native, but needs Script Editor notification permission)
    script = f"display notification {_lit(message)} with title {_lit(title)}"
    if subtitle:
        script += f" subtitle {_lit(subtitle)}"
    if sound:
        script += f" sound name {_lit(sound)}"
    await _run("osascript", "-e", script)


def _message(rec: dict, bike: str) -> tuple[str, str, str] | None:
    """(title, message, sound) for an event record, or None to skip."""
    ev, d = rec["event"], rec.get("data", {})
    lvl = d.get("level")
    table = {
        "battery.full": ("🔋 Battery fully charged", f"{bike} is at 100%", "Glass"),
        "battery.low": (f"🪫 Battery low — {lvl}%", f"{bike} needs a charge", "Basso"),
        "battery.charging_started": ("⚡ Charging started", f"{bike} at {lvl}%", "Glass"),
        "battery.charging_stopped": ("🔌 Charging stopped", f"{bike} at {lvl}%", "Glass"),
        "charger.connected": ("🔌 Charger connected", bike, None),
        "charger.disconnected": ("🔌 Charger unplugged", bike, None),
        "ride.completed": ("🚲 Ride logged",
                           f"{d.get('distance_km', '?')} km on {bike}", "Glass"),
        "firmware.changed": (f"🔧 {d.get('component', 'component')} updated",
                             f"→ {d.get('to')}", None),
    }
    return table.get(ev)


async def for_event(rec: dict, bike: str) -> None:
    m = _message(rec, bike)
    if m:
        await send(m[0], m[1], subtitle=None, sound=m[2])
