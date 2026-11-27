"""Export explicitly mapped daily PTDS observations; original values stay local."""
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
EXTRA = {
    "oura": [("HRV", "hrv_ms", "ms", 10000), ("LOWEST_HR", "night_lowest_hr", "bpm", 500),
             ("RESP_RATE", "sleep_respiration", "次/分", 150), ("SPO2", "spo2_percent", "%", 100),
             ("TEMP_DEV", "temperature_deviation", "°C", 100), ("CAL_TOTAL", "total_calories", "kcal", 50000),
             ("CAL_ACTIVE", "active_calories", "kcal", 50000), ("TIME_IN_BED", "time_in_bed", "min", 1440),
             ("READINESS_SCORE", "readiness_score", "score", 100), ("SLEEP_SCORE", "sleep_score", "score", 100),
             ("ACTIVITY_SCORE", "activity_score", "score", 100)],
    "garmin": [("HRV_NIGHT", "hrv_ms", "ms", 10000), ("RESTING_HR", "resting_hr", "bpm", 500),
               ("HR_MIN", "lowest_hr", "bpm", 500), ("HR_MAX", "highest_hr", "bpm", 500),
               ("STRESS_AVG", "stress", "score", 100), ("BATTERY_MAX", "body_battery_high", "score", 100),
               ("BATTERY_MIN", "body_battery_low", "score", 100), ("SPO2_AVG", "spo2_percent", "%", 100),
               ("SPO2_MIN", "spo2_min", "%", 100), ("RESP_AWAKE", "respiration", "brpm", 150),
               ("RESP_SLEEP", "sleep_respiration", "brpm", 150), ("CAL_TOTAL", "total_calories", "kcal", 50000),
               ("CAL_ACTIVE", "active_calories", "kcal", 50000),
               *[("SLEEP_" + code, field + "_minutes", "s", 86400) for code, field in [("DEEP", "deep"), ("LIGHT", "light"), ("REM", "rem"), ("AWAKE", "awake")]]],
    "somaloop": [("DISTANCE_DAY", "distance_km", "km", 1000), ("CAL_DAY", "total_calories", "kcal", 50000),
                 ("HRV_DAY", "hrv_ms", "ms", 10000), ("LOAD_DAY", "load", "1", 1000000),
                 ("SPO2_DAY", "spo2_percent", "%", 100), ("TEMP_DEV_DAY", "temperature_deviation", "°C", 100)],
}


def read_metric(port, space, day, code, unit, maximum, source="oura"):
    query = urlencode({
        "key": space, "view": "series", "category": "wearable",
        "code": code, "sources": "DEVICE_" + source.upper(), "from": day,
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
            or not isinstance(raw, str) or not re.fullmatch(r"-?[0-9]{1,7}(?:\.[0-9]{1,8})?", raw)):
        raise ValueError(f"Unexpected observation format for {code}.")
    value = float(raw)
    if value > maximum or value < (-100 if "TEMP_DEV" in code else 0):
        raise ValueError(f"Observation for {code} is out of range.")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8780, help="Port in the local PTDS address")
    parser.add_argument("--space", required=True, help="PTDS instance key")
    parser.add_argument("--date", required=True, type=date.fromisoformat, help="PTDS observation date (YYYY-MM-DD)")
    parser.add_argument("--output", required=True, type=Path, help="New summary JSON file")
    parser.add_argument("--source", choices=list(EXTRA), default="oura")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not args.space.strip():
        parser.error("Specify a valid PTDS port and space key.")
    day = args.date.isoformat()
    summary = {"schema": "xiuxian.wearable.v2", "date": day, "source": args.source, "metrics": {}}
    try:
        primary = {"oura": METRICS, "garmin": (("GARMIN_STEPS", "steps", "steps", 1000000), ("GARMIN_SLEEP_SECONDS", "sleep_minutes", "s", 86400)),
                   "somaloop": (("SOMALOOP_AGENT_STEPS_DAY", "steps", "steps", 1000000),)}[args.source]
        for code, field, unit, maximum in primary:
            value = read_metric(args.port, args.space, day, code, unit, maximum, args.source)
            if value is not None:
                if not value.is_integer():
                    raise ValueError(f"Non-integral count for {code}")
                summary[field] = int(value // 60 if unit == "s" else value)
        prefix = "SOMALOOP_AGENT_" if args.source == "somaloop" else args.source.upper() + "_"
        for suffix, field, unit, maximum in EXTRA[args.source]:
            value = read_metric(args.port, args.space, day, prefix + suffix, unit, maximum, args.source)
            if value is not None:
                summary["metrics"][field] = value / 60 if unit == "s" else value
        if "steps" not in summary and "sleep_minutes" not in summary and not summary["metrics"]:
            raise ValueError("No supported daily observations on this date. Missing data is not substituted.")
        with args.output.open("x", encoding="utf-8", newline="\n") as output:
            json.dump(summary, output, ensure_ascii=False, allow_nan=False, indent=2)
            output.write("\n")
    except (OSError, HTTPException, ValueError) as error:
        parser.exit(1, f"Export failed: {error}\n")
    print(f"Summary written to {args.output}")


if __name__ == "__main__":
    main()
