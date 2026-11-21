"""Export one day of Oura observations from PTDS v0.3.0-alpha.2."""
import argparse
from datetime import date
from http.client import HTTPConnection, HTTPException
import json
from pathlib import Path
import re
from urllib.parse import urlencode


METRICS = (
    ("OURA_STEPS", "steps", "steps", 1_000_000),
    ("OURA_TOTAL_SLEEP", "sleep_minutes", "min", 1440),
)
MAX_RESPONSE = 64 * 1024


def read_metric(port, space, day, code, unit, maximum):
    query = urlencode({
        "key": space, "view": "series", "category": "wearable",
        "code": code, "sources": "DEVICE_OURA", "from": day,
        "to": day, "limit": 2,
    })
    # A direct loopback request avoids system proxies and never follows redirects.
    conn = HTTPConnection("127.0.0.1", port, timeout=8)
    try:
        conn.request("GET", "/api/data/read?" + query, headers={"Accept": "application/json"})
        response = conn.getresponse()
        if response.status != 200:
            raise ValueError(f"PTDS returned HTTP {response.status}. Check its port and space key.")
        body = response.read(MAX_RESPONSE + 1)
    finally:
        conn.close()
    if len(body) > MAX_RESPONSE:
        raise ValueError("PTDS response exceeded the expected size.")
    payload = json.loads(body)
    if (not isinstance(payload, dict) or payload.get("projection") != "data-read/1"
            or payload.get("view") != "series" or not isinstance(payload.get("items"), list)):
        raise ValueError("Unexpected PTDS series response.")
    points = payload["items"]
    if payload.get("has_more") is not False or payload.get("total") != len(points) or len(points) > 1:
        raise ValueError(f"PTDS returned multiple or incomplete observations for {code} on this date.")
    if not points:
        return None
    point = points[0]
    if not isinstance(point, dict):
        raise ValueError(f"Unexpected PTDS point for {code}.")
    raw = point.get("raw")
    if (point.get("tp") != day or point.get("unit") != unit or not point.get("ref")
            or point.get("comparator") or point.get("missing") is not False
            or not isinstance(raw, str) or not re.fullmatch(r"[0-9]{1,7}(?:\.0+)?", raw)):
        raise ValueError(f"Unexpected observation format for {code}.")
    value = int(raw.split(".")[0])
    if value > maximum:
        raise ValueError(f"Observation for {code} is out of range.")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8780, help="Port in the local PTDS address")
    parser.add_argument("--space", required=True, help="PTDS instance key")
    parser.add_argument("--date", required=True, type=date.fromisoformat, help="PTDS observation date (YYYY-MM-DD)")
    parser.add_argument("--output", required=True, type=Path, help="New summary JSON file")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not args.space.strip():
        parser.error("Specify a valid PTDS port and space key.")
    day = args.date.isoformat()
    summary = {"schema": "xiuxian.ptds-oura.v1", "date": day}
    try:
        for code, field, unit, maximum in METRICS:
            value = read_metric(args.port, args.space, day, code, unit, maximum)
            if value is not None:
                summary[field] = value
        if len(summary) == 2:
            raise ValueError("No Oura steps or total sleep were found on this date.")
        with args.output.open("x", encoding="utf-8", newline="\n") as output:
            json.dump(summary, output, ensure_ascii=False, allow_nan=False, indent=2)
            output.write("\n")
    except (OSError, HTTPException, ValueError) as error:
        parser.exit(1, f"Export failed: {error}\n")
    print(f"Summary written to {args.output}")


if __name__ == "__main__":
    main()
