"""Render normalized ride tracks as GPX and GeoJSON."""
from __future__ import annotations

from xml.sax.saxutils import escape


def to_gpx(ride: dict) -> str:
    name = escape(ride.get("title") or "eBike ride")
    pts = ride.get("track") or []
    rows = []
    for p in pts:
        t = f"<time>{p['time']}</time>" if p.get("time") else ""
        rows.append(f'<trkpt lat="{p["lat"]}" lon="{p["lon"]}">{t}</trkpt>')
    body = "\n".join(rows)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<gpx version="1.1" creator="bosch-flow" xmlns="http://www.topografix.com/GPX/1/1">\n'
        f"<trk><name>{name}</name><trkseg>\n{body}\n</trkseg></trk>\n</gpx>\n"
    )


def to_geojson(rides: list[dict]) -> dict:
    features = []
    for r in rides:
        coords = [[p["lon"], p["lat"]] for p in (r.get("track") or [])]
        if len(coords) < 2:
            continue
        features.append({
            "type": "Feature",
            "properties": {
                "id": r.get("id"),
                "title": r.get("title"),
                "start": r.get("start"),
                "distance_km": r.get("distance_km"),
            },
            "geometry": {"type": "LineString", "coordinates": coords},
        })
    return {"type": "FeatureCollection", "features": features}
