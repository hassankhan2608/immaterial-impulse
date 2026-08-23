#!/usr/bin/env python3
"""Screen Time data helper — a Daylog-style pipeline for the Omarchy Quickshell plugin.

Reads ActivityWatch's SQLite database directly and outputs JSON for the
Today, Week, and Month views.  No external dependencies — stdlib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _data_home() -> Path:
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg)
    return Path.home() / ".local" / "share"


def db_path() -> Path:
    return _data_home() / "activitywatch" / "aw-server-rust" / "sqlite.db"


# ---------------------------------------------------------------------------
# SQLite helpers
# ---------------------------------------------------------------------------

_conn: sqlite3.Connection | None = None


def _get_conn() -> sqlite3.Connection:
    global _conn
    if _conn is not None:
        return _conn
    path = db_path()
    if not path.exists():
        raise FileNotFoundError(str(path))
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    _conn = conn
    return conn


def _bucket_ids(prefix: str) -> list[int]:
    conn = _get_conn()
    # Capped so a database stuffed with fake bucket rows can neither
    # materialize an unbounded id list nor inflate the SQL placeholder count.
    rows = conn.execute(
        "SELECT id FROM buckets WHERE name LIKE ?1 ORDER BY id LIMIT ?2",
        (prefix + "%", MAX_BUCKETS_PER_PREFIX),
    ).fetchall()
    return [r["id"] for r in rows]


def _events_in_range(
    bucket_prefix: str, start_ns: int, end_ns: int
) -> list[dict[str, Any]]:
    conn = _get_conn()
    bids = _bucket_ids(bucket_prefix)
    if not bids:
        return []
    placeholders = ",".join("?" * len(bids))
    # Resource ceilings: a hostile or corrupt database must not be able to
    # exhaust shell memory through this helper. The cursor is iterated lazily
    # (no fetchall) with newest-first ordering; item count, per-event
    # size/duration, and the aggregate retained-event budget — raw data plus
    # a conservative per-object overhead — are enforced as rows stream in.
    # Breaking out stops pulling rows at all, so nothing is materialized
    # before it is charged against the budget.
    cur = conn.execute(
        f"SELECT id, starttime, endtime, data FROM events "
        f"WHERE bucketrow IN ({placeholders}) AND endtime >= ? AND starttime <= ? "
        f"ORDER BY starttime DESC LIMIT {MAX_EVENTS_PER_QUERY}",
        (*bids, start_ns, end_ns),
    )
    events: list[dict[str, Any]] = []
    retained_budget = 0
    for r in cur:
        st_ns = max(r["starttime"], start_ns)
        et_ns = min(r["endtime"], end_ns)
        if et_ns <= st_ns:
            continue
        ts = datetime.fromtimestamp(st_ns / 1e9, tz=timezone.utc)
        dur = (et_ns - st_ns) / 1e9
        if dur > MAX_EVENT_DURATION_SECS:
            dur = MAX_EVENT_DURATION_SECS
        raw_data = r["data"] or ""
        if len(raw_data) > MAX_EVENT_DATA_BYTES:
            data = {}
            data_len = 0
        else:
            data_len = len(raw_data)
            try:
                data = json.loads(raw_data)
            except (json.JSONDecodeError, TypeError):
                data = {}
        charge = EVENT_OBJECT_OVERHEAD_BYTES + data_len
        if retained_budget + charge > MAX_RETAINED_EVENT_BUDGET:
            break
        retained_budget += charge
        events.append(
            {
                "id": r["id"],
                "timestamp": ts.isoformat(),
                "timestamp_utc": ts,
                "duration": dur,
                "data": data,
            }
        )
    events.reverse()
    return events


# ---------------------------------------------------------------------------
# Time ranges  (all boundaries in nanoseconds since epoch)
# ---------------------------------------------------------------------------

def _to_ns(dt: datetime) -> int:
    return int(dt.timestamp() * 1e9)


def _local_midnight(days_ago: int = 0) -> datetime:
    now = datetime.now().astimezone()
    target = (now - timedelta(days=days_ago)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return target.astimezone(timezone.utc)


def today_range() -> tuple[int, int]:
    start = _local_midnight(0)
    end = _local_midnight(-1)
    return _to_ns(start), _to_ns(end)


def days_ago_range(days: int) -> tuple[int, int]:
    start = _local_midnight(days)
    end = _local_midnight(days - 1)
    return _to_ns(start), _to_ns(end)


def last_n_days_range(n: int) -> tuple[int, int]:
    end_dt = _local_midnight(-1)  # start of tomorrow = end of today
    start_dt = _local_midnight(n - 1)
    return _to_ns(start_dt), _to_ns(end_dt)


# ---------------------------------------------------------------------------
# Transforms (ported from Daylog Rust code)
# ---------------------------------------------------------------------------

PULSE_SECS = 5.0

BUCKET_WINDOW = "aw-watcher-window_"
BUCKET_AFK = "aw-watcher-afk_"
BUCKET_WEB = "aw-watcher-web-"

# Resource ceilings (see _events_in_range): bound what a hostile or corrupt
# database can push through the helper into the shell.
MAX_EVENTS_PER_QUERY = 200_000
MAX_EVENT_DURATION_SECS = 86_400.0
MAX_EVENT_DATA_BYTES = 16_384
MAX_LABEL_CHARS = 100
MAX_PAYLOAD_BYTES = 2_000_000
# Aggregate budget for retained events across one query, enforced while
# ingesting (newest events preferred). Every retained event is charged its
# raw data size PLUS a conservative per-object overhead covering the dict,
# datetime, isoformat string, and id — so the entire retained shape is
# bounded, including events whose data is empty or was skipped as oversized.
# Derived structures (flood, intersection, aggregation) are O(retained).
MAX_RETAINED_EVENT_BUDGET = 32_000_000
EVENT_OBJECT_OVERHEAD_BYTES = 512
# Bucket discovery and intersection outputs are also bounded: a hostile
# database full of fake bucket rows or alternating window/AFK overlaps must
# not inflate the query string or multiply the intersect output.
MAX_BUCKETS_PER_PREFIX = 32
MAX_INTERSECT_OUTPUT_EVENTS = 200_000


def _trunc(value: str, limit: int = MAX_LABEL_CHARS) -> str:
    return value if len(value) <= limit else value[: limit - 1] + "\u2026"


def _bound_payload(payload: dict) -> dict:
    """Cap the serialized size handed to the shell.

    Degradation is graceful: if a (pathological) payload exceeds the cap,
    drop the heaviest detail first (the today timeline), then fail with a
    tiny error payload instead of an unbounded document.
    """
    if len(json.dumps(payload, cls=_Encoder)) <= MAX_PAYLOAD_BYTES:
        return payload
    trimmed = dict(payload)
    if "timeline" in trimmed:
        trimmed["timeline"] = trimmed["timeline"][-2000:]
        if len(json.dumps(trimmed, cls=_Encoder)) <= MAX_PAYLOAD_BYTES:
            return trimmed
    return {
        "error": "payload too large",
        "tracker_online": bool(payload.get("tracker_online", True)),
    }


def _sort_by_timestamp(events: list[dict]) -> list[dict]:
    return sorted(events, key=lambda e: e["timestamp_utc"])


def _sort_by_duration(events: list[dict], desc: bool = True) -> list[dict]:
    return sorted(events, key=lambda e: e["duration"], reverse=desc)


def _filter_keyvals(
    events: list[dict], key: str, values: list[Any]
) -> list[dict]:
    return [
        e for e in events if e["data"].get(key) in values
    ]


def _merge_events_by_keys(events: list[dict], keys: list[str]) -> list[dict]:
    merged: dict[str, dict] = {}
    for ev in events:
        composite = tuple(ev["data"].get(k) for k in keys)
        if any(v is None for v in composite):
            continue
        # Values may be lists (e.g. $category), which are unhashable — use the
        # JSON encoding as the map key instead.
        map_key = json.dumps(composite)
        if map_key in merged:
            merged[map_key]["duration"] += ev["duration"]
        else:
            data = {k: ev["data"][k] for k in keys}
            merged[map_key] = {
                "timestamp_utc": ev["timestamp_utc"],
                "timestamp": ev["timestamp"],
                "duration": ev["duration"],
                "data": data,
            }
    return list(merged.values())


def _filter_period_intersect(
    events: list[dict], filter_events: list[dict]
) -> list[dict]:
    ev_sorted = _sort_by_timestamp(events)
    filt_sorted = _sort_by_timestamp(filter_events)
    out: list[dict] = []
    cursor = 0
    for ev in ev_sorted:
        if len(out) >= MAX_INTERSECT_OUTPUT_EVENTS:
            break
        ev_start = ev["timestamp_utc"]
        ev_end = ev_start + timedelta(seconds=ev["duration"])
        while cursor < len(filt_sorted):
            fe = filt_sorted[cursor]
            fe_end = fe["timestamp_utc"] + timedelta(seconds=fe["duration"])
            if fe_end <= ev_start:
                cursor += 1
            else:
                break
        i = cursor
        while i < len(filt_sorted):
            fe = filt_sorted[i]
            fe_start = fe["timestamp_utc"]
            fe_end = fe_start + timedelta(seconds=fe["duration"])
            if fe_start >= ev_end:
                break
            new_start = max(ev_start, fe_start)
            new_end = min(ev_end, fe_end)
            if new_end > new_start:
                # Hard bound: hostile overlapping window/AFK rows must not
                # turn this two-pointer sweep into quadratic output.
                if len(out) >= MAX_INTERSECT_OUTPUT_EVENTS:
                    return out
                dur = (new_end - new_start).total_seconds()
                out.append(
                    {
                        "id": ev.get("id"),
                        "timestamp_utc": new_start,
                        "timestamp": new_start.isoformat(),
                        "duration": dur,
                        "data": ev["data"],
                    }
                )
            i += 1
    return out


def _flood(events: list[dict], pulsetime: float = PULSE_SECS) -> list[dict]:
    """Port of aw-transform flood: bridge gaps shorter than pulsetime.

    Same-data neighbours merge; different-data neighbours meet in the middle
    of the gap (each side grows by half). Mirrors the Rust iterator version:
    e2 is peeked, only consumed on merge.
    """
    evs = _sort_by_timestamp(events)
    result: list[dict] = []
    gap_prev: float | None = None
    i = 0

    while i < len(evs):
        e1 = dict(evs[i])
        i += 1

        if gap_prev is not None:
            half = timedelta(seconds=gap_prev / 2)
            e1["timestamp_utc"] -= half
            e1["duration"] += gap_prev / 2
            gap_prev = None

        # Retry loop: e1 may absorb following same-data events.
        while True:
            e1_start = e1["timestamp_utc"]
            e1_end = e1_start + timedelta(seconds=e1["duration"])

            if i >= len(evs):
                result.append(e1)
                i = len(evs) + 1  # signal outer loop to stop
                break

            e2 = evs[i]
            e2_start = e2["timestamp_utc"]
            e2_end = e2_start + timedelta(seconds=e2["duration"])
            gap = (e2_start - e1_end).total_seconds()

            if gap < 0 and e1["data"] == e2["data"]:
                # Overlapping same-data events: merge into one.
                start = min(e1_start, e2_start)
                end = max(e1_end, e2_end)
                e1 = {
                    **e1,
                    "timestamp_utc": start,
                    "duration": (end - start).total_seconds(),
                }
                i += 1
                continue
            if 0 <= gap < pulsetime:
                if e1["data"] == e2["data"]:
                    start = min(e1_start, e2_start)
                    end = max(e1_end, e2_end)
                    e1 = {
                        **e1,
                        "timestamp_utc": start,
                        "duration": (end - start).total_seconds(),
                    }
                    i += 1
                    continue
                # Different data: extend to the middle of the gap; the next
                # event will be pulled back by the other half (gap_prev).
                e1["duration"] += gap / 2
                gap_prev = gap
            # gap < 0 with different data (significant overlap) passes
            # through unchanged, matching upstream behaviour.
            result.append(e1)
            break

        if i > len(evs):
            break

    return result


# ---------------------------------------------------------------------------
# Categories (default rules matching Daylog)
# ---------------------------------------------------------------------------

DEFAULT_CATEGORIES = [
    {"name": ["Work", "Programming"], "regex": r"(?i)(?:code|cursor|vscode|atom|sublime|intellij|jetbrains|webstorm|pycharm|rustrover|goland|clion|rider|android\.studio|xcode|emacs|vim|neovim|nvim|zed|helix|kitty|alacritty|wezterm|ghostty|gnome-terminal|konsole|xterm|tilix|terminator|activitywatch|aw-|daylog)"},
    {"name": ["Work", "Documents"], "regex": r"(?i)(?:libreoffice|writer|calc|impress|notion|obsidian|joplin|evernote|onenote|logseq)"},
    {"name": ["Work", "Image"], "regex": r"(?i)(?:gimp|krita|inkscape|figma|photoshop|illustrator|affinity)"},
    {"name": ["Work", "3D"], "regex": r"(?i)(?:blender|fusion 360|sketchup)"},
    {"name": ["Work", "Video"], "regex": r"(?i)(?:kdenlive|davinci|premiere|after effects|obs studio)"},
    {"name": ["Media", "Music"], "regex": r"(?i)(?:spotify|rhythmbox|youtube music|apple music|tidal|deezer)"},
    {"name": ["Media", "Video"], "regex": r"(?i)(?:mpv|vlc|youtube|netflix|plex|jellyfin)"},
    {"name": ["Media", "Games"], "regex": r"(?i)(?:steam|lutris|heroic|minecraft)"},
    {"name": ["Media", "Social"], "regex": r"(?i)(?:twitter|x\.com|reddit|facebook|instagram|tiktok|mastodon|bluesky|threads)"},
    {"name": ["Comms", "IM"], "regex": r"(?i)(?:slack|discord|telegram|signal|element|riot|whatsapp|messenger)"},
    {"name": ["Comms", "Email"], "regex": r"(?i)(?:thunderbird|geary|evolution|gmail|outlook|protonmail|fastmail)"},
    {"name": ["Browsing"], "regex": r"(?i)(?:firefox|brave|chromium|chrome|vivaldi|librewolf|zen browser|edge)"},
]

_compiled_rules: list[tuple[list[str], re.Pattern | None]] | None = None


def _get_rules() -> list[tuple[list[str], re.Pattern | None]]:
    global _compiled_rules
    if _compiled_rules is not None:
        return _compiled_rules
    rules: list[tuple[list[str], re.Pattern | None]] = []
    for cat in DEFAULT_CATEGORIES:
        try:
            pat = re.compile(cat["regex"])
        except re.error:
            pat = None
        rules.append((cat["name"], pat))
    rules.append((["Uncategorized"], None))
    _compiled_rules = rules
    return rules


def _categorize_one(ev: dict) -> dict:
    data = ev["data"]
    chosen = ["Uncategorized"]
    rules = _get_rules()
    for cat_name, pat in rules:
        if pat is None:
            continue
        for v in data.values():
            if isinstance(v, str) and pat.search(v):
                if len(cat_name) >= len(chosen):
                    chosen = cat_name
                break
    data["$category"] = chosen
    return ev


def _categorize(events: list[dict]) -> list[dict]:
    return [_categorize_one(dict(e)) for e in events]


def category_root(cat_path: list[str]) -> str:
    return cat_path[0] if cat_path else "Uncategorized"


# ---------------------------------------------------------------------------
# URL splitting
# ---------------------------------------------------------------------------

def _split_url_events(events: list[dict]) -> list[dict]:
    for ev in events:
        url_str = ev["data"].get("url")
        if not isinstance(url_str, str):
            continue
        try:
            parsed = urlparse(url_str)
            host = parsed.hostname or ""
            host = host.removeprefix("www.")
            ev["data"]["$domain"] = host
        except Exception:
            pass
    return events


# ---------------------------------------------------------------------------
# KPI computations
# ---------------------------------------------------------------------------

FOCUS_FLOOR_SECS = 120.0
PATTERN_SHIFT_NOISE_FLOOR_SECS = 900.0  # 15 min
WINDOW_HOURS = 3


def _focus_by_hour(
    events: list[dict], floor: float = FOCUS_FLOOR_SECS
) -> list[float]:
    hours = [0.0] * 24
    if not events:
        return hours
    sorted_ev = sorted(events, key=lambda e: e["timestamp_utc"])
    local_tz = datetime.now().astimezone().tzinfo

    run_start = 0
    run_root: str | None = category_root(sorted_ev[0]["data"].get("$category", []))
    run_secs = 0.0

    def flush(start, end, secs):
        if secs < floor:
            return
        for ev in sorted_ev[start:end]:
            h = ev["timestamp_utc"].astimezone(local_tz).hour
            if 0 <= h < 24:
                hours[h] += ev["duration"]

    for i in range(1, len(sorted_ev)):
        root = category_root(sorted_ev[i]["data"].get("$category", []))
        if root != run_root:
            flush(run_start, i, run_secs)
            run_start = i
            run_root = root
            run_secs = sorted_ev[i]["duration"]
        else:
            run_secs += sorted_ev[i]["duration"]
    flush(run_start, len(sorted_ev), run_secs)
    return hours


def _longest_focus(
    events: list[dict], floor: float = FOCUS_FLOOR_SECS
) -> dict | None:
    if not events:
        return None
    sorted_ev = sorted(events, key=lambda e: e["timestamp_utc"])
    best: tuple[float, str] | None = None
    run_secs = 0.0
    run_root: str | None = None

    def consider(secs, root):
        nonlocal best
        if secs >= floor and root is not None:
            if best is None or secs > best[0]:
                best = (secs, root)

    for ev in sorted_ev:
        root = category_root(ev["data"].get("$category", []))
        if run_root != root:
            consider(run_secs, run_root)
            run_root = root
            run_secs = ev["duration"]
        else:
            run_secs += ev["duration"]
    consider(run_secs, run_root)
    if best:
        return {"seconds": best[0], "category_root": best[1]}
    return None


def _best_window(
    focus_hours: list[float], window: int = WINDOW_HOURS
) -> dict | None:
    best_start = 0
    best_sum = 0.0
    for start in range(24 - window + 1):
        s = sum(focus_hours[start : start + window])
        if s > best_sum:
            best_sum = s
            best_start = start
    if best_sum == 0:
        return None
    return {
        "start_hour": best_start,
        "end_hour": best_start + window,
        "seconds": best_sum,
    }


def _pattern_shift(
    today_events: list[dict],
    past_days: list[list[dict]],
    today_weekday: str,
) -> dict | None:
    if not past_days:
        return None
    today_totals: dict[str, float] = {}
    all_roots: set[str] = set()
    for ev in today_events:
        root = category_root(ev["data"].get("$category", []))
        today_totals[root] = today_totals.get(root, 0) + ev["duration"]
        all_roots.add(root)
    for day in past_days:
        for ev in day:
            all_roots.add(category_root(ev["data"].get("$category", [])))

    best: tuple[str, float] | None = None
    for root in all_roots:
        today_s = today_totals.get(root, 0)
        past_samples = []
        for day in past_days:
            s = sum(
                ev["duration"]
                for ev in day
                if category_root(ev["data"].get("$category", [])) == root
            )
            past_samples.append(s)
        if not past_samples:
            continue
        past_samples.sort()
        n = len(past_samples)
        median = (past_samples[n // 2] + past_samples[(n - 1) // 2]) / 2
        delta = today_s - median
        if best is None or abs(delta) > abs(best[1]):
            best = (root, delta)

    if best and abs(best[1]) >= PATTERN_SHIFT_NOISE_FLOOR_SECS:
        return {
            "category_root": best[0],
            "delta_secs": best[1],
            "weekday": today_weekday,
        }
    return None


# ---------------------------------------------------------------------------
# Hourly bucketization
# ---------------------------------------------------------------------------

def _bucketize_hourly(events: list[dict]) -> list[dict]:
    totals = [0.0] * 24
    local_tz = datetime.now().astimezone().tzinfo
    for ev in events:
        if ev["duration"] <= 0:
            continue
        remaining = ev["duration"]
        cursor = ev["timestamp_utc"]
        for _ in range(24 * 32):
            if remaining <= 0:
                break
            local = cursor.astimezone(local_tz)
            h = local.hour
            next_local = (local + timedelta(hours=1)).replace(
                minute=0, second=0, microsecond=0
            )
            next_utc = next_local.astimezone(timezone.utc)
            span = (next_utc - cursor).total_seconds()
            if span <= 0:
                break
            chunk = min(remaining, span)
            if 0 <= h < 24:
                totals[h] += chunk
            remaining -= chunk
            cursor = next_utc
    return [{"hour": i, "duration": totals[i]} for i in range(24)]


# ---------------------------------------------------------------------------
# AFK summarization
# ---------------------------------------------------------------------------

def _summarize_afk(events: list[dict]) -> dict:
    active = 0.0
    afk = 0.0
    for ev in events:
        status = ev["data"].get("status", "")
        if status == "not-afk":
            active += ev["duration"]
        elif status == "afk":
            afk += ev["duration"]
    total = active + afk
    ratio = active / total if total > 0 else 0.0
    return {"active_seconds": active, "afk_seconds": afk, "active_ratio": ratio}


# ---------------------------------------------------------------------------
# Core query pipeline
# ---------------------------------------------------------------------------

def _active_events(start_ns: int, end_ns: int) -> list[dict]:
    window = _events_in_range(BUCKET_WINDOW, start_ns, end_ns)
    afk = _events_in_range(BUCKET_AFK, start_ns, end_ns)
    flooded = _flood(window, PULSE_SECS)
    not_afk = _filter_keyvals(afk, "status", ["not-afk"])
    return _filter_period_intersect(flooded, not_afk)


def _categorized_active(start_ns: int, end_ns: int) -> list[dict]:
    events = _active_events(start_ns, end_ns)
    return _categorize(events)


def _compute_top_apps(
    events: list[dict], limit: int = 5
) -> list[dict]:
    merged = _merge_events_by_keys(events, ["app"])
    sorted_ev = _sort_by_duration(merged)
    out = []
    for ev in sorted_ev[:limit]:
        name = ev["data"].get("app", "unknown")
        if not isinstance(name, str) or not name:
            name = "unknown"
        out.append({"name": _trunc(name), "duration_secs": ev["duration"]})
    return out


def _compute_top_categories(
    events: list[dict], limit: int = 5
) -> list[dict]:
    merged = _merge_events_by_keys(events, ["$category"])
    sorted_ev = _sort_by_duration(merged)
    out = []
    for ev in sorted_ev[:limit]:
        cat = ev["data"].get("$category", ["Uncategorized"])
        if not isinstance(cat, list):
            cat = ["Uncategorized"]
        out.append({"name": cat, "duration_secs": ev["duration"]})
    return out


def _compute_top_domains(
    start_ns: int, end_ns: int, limit: int = 5
) -> list[dict]:
    web = _events_in_range(BUCKET_WEB, start_ns, end_ns)
    if not web:
        return []
    web = _split_url_events(web)
    afk = _events_in_range(BUCKET_AFK, start_ns, end_ns)
    not_afk = _filter_keyvals(afk, "status", ["not-afk"])
    intersected = _filter_period_intersect(web, not_afk)
    merged = _merge_events_by_keys(intersected, ["$domain"])
    sorted_ev = _sort_by_duration(merged)
    out = []
    for ev in sorted_ev[:limit]:
        domain = ev["data"].get("$domain", "unknown")
        if not isinstance(domain, str) or not domain:
            domain = "unknown"
        out.append({"domain": _trunc(domain), "duration_secs": ev["duration"]})
    return out


# ---------------------------------------------------------------------------
# CLI commands
# ---------------------------------------------------------------------------

def cmd_status() -> dict:
    path = db_path()
    online = path.exists()
    return {"online": online, "db_path": str(path)}


def cmd_today() -> dict:
    start_ns, end_ns = today_range()
    active = _active_events(start_ns, end_ns)
    categorized = _categorize(active)

    afk_events = _events_in_range(BUCKET_AFK, start_ns, end_ns)
    afk_summary = _summarize_afk(afk_events)

    # KPIs
    focus_hours = _focus_by_hour(categorized)
    longest = _longest_focus(categorized)
    best_win = _best_window(focus_hours)

    # Past 7 days for pattern shift
    past_days_events: list[list[dict]] = []
    for d in range(1, 8):
        ps, pe = days_ago_range(d)
        ce = _categorized_active(ps, pe)
        past_days_events.append(ce)

    today_weekday = datetime.now().astimezone().strftime("%a")
    pattern = _pattern_shift(categorized, past_days_events, today_weekday)

    # Timeline
    timeline = []
    for ev in sorted(categorized, key=lambda e: e["timestamp_utc"]):
        timeline.append(
            {
                "timestamp": ev["timestamp"],
                "duration": ev["duration"],
                "category": ev["data"].get("$category", ["Uncategorized"]),
            }
        )

    # Hourly
    hourly = _bucketize_hourly(active)

    # Top lists
    top_apps = _compute_top_apps(categorized)
    top_categories = _compute_top_categories(categorized)
    top_domains = _compute_top_domains(start_ns, end_ns)

    return {
        "active_secs": round(afk_summary["active_seconds"], 1),
        "afk_secs": round(afk_summary["afk_seconds"], 1),
        "longest_stretch": longest,
        "best_window": best_win,
        "pattern_shift": pattern,
        "timeline": timeline,
        "hourly": hourly,
        "top_apps": top_apps,
        "top_categories": top_categories,
        "top_domains": top_domains,
        "tracker_online": True,
    }


def _iso_week_start_end() -> tuple[datetime, datetime]:
    now = datetime.now().astimezone()
    weekday = now.weekday()  # Mon=0
    monday = (now - timedelta(days=weekday)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    sunday = monday + timedelta(days=7)
    return monday.astimezone(timezone.utc), sunday.astimezone(timezone.utc)


def cmd_week() -> dict:
    monday, next_monday = _iso_week_start_end()
    start_ns = _to_ns(monday)
    end_ns = _to_ns(next_monday)

    # Build per-day data for the 7 days of this ISO week
    local_tz = datetime.now().astimezone().tzinfo
    now_local = datetime.now().astimezone()
    days: list[dict] = []
    all_active_total = 0.0
    best_day: dict | None = None
    days_with_data = 0
    day_active: list[float] = []

    for d in range(7):
        day_start = monday + timedelta(days=d)
        day_end = day_start + timedelta(days=1)
        ds = _to_ns(day_start)
        de = _to_ns(day_end)
        is_future = day_start.astimezone(local_tz) > now_local

        if is_future:
            days.append(
                {
                    "weekday": day_start.astimezone(local_tz).strftime("%a"),
                    "date": day_start.astimezone(local_tz).strftime("%b %d"),
                    "total_secs": 0,
                    "is_future": True,
                    "is_peak": False,
                    "roots": [],
                }
            )
            continue

        categorized = _categorized_active(ds, de)
        total = sum(ev["duration"] for ev in categorized)
        all_active_total += total
        day_active.append(total)
        days_with_data += 1

        if best_day is None or total > best_day["secs"]:
            best_day = {
                "date": day_start.astimezone(local_tz).strftime("%a, %b %d"),
                "secs": round(total, 1),
            }

        # Category roots
        root_totals: dict[str, float] = {}
        for ev in categorized:
            root = category_root(ev["data"].get("$category", []))
            root_totals[root] = root_totals.get(root, 0) + ev["duration"]
        roots = [
            {"name": k, "secs": round(v, 1)}
            for k, v in sorted(root_totals.items(), key=lambda x: -x[1])
        ]

        days.append(
            {
                "weekday": day_start.astimezone(local_tz).strftime("%a"),
                "date": day_start.astimezone(local_tz).strftime("%b %d"),
                "total_secs": round(total, 1),
                "is_future": False,
                "is_peak": False,
                "roots": roots,
            }
        )

    # Mark peak
    if best_day:
        for day in days:
            if not day["is_future"] and day["total_secs"] == best_day["secs"]:
                day["is_peak"] = True
                break

    daily_avg = all_active_total / days_with_data if days_with_data > 0 else 0

    # Top lists for 7-day range
    all_categorized = _categorized_active(start_ns, end_ns)
    top_apps = _compute_top_apps(all_categorized)
    top_categories = _compute_top_categories(all_categorized)
    top_domains = _compute_top_domains(start_ns, end_ns)

    return {
        "total_active_secs": round(all_active_total, 1),
        "daily_avg_secs": round(daily_avg, 1),
        "avg_over_days": days_with_data,
        "best_day": best_day,
        "days": days,
        "top_apps": top_apps,
        "top_categories": top_categories,
        "top_domains": top_domains,
        "tracker_online": True,
    }


def _daily_totals(
    events: list[dict], start_date, num_days: int
) -> dict:
    """Sum event durations per local calendar day, splitting at midnight.

    Mirrors per-day queries (which clip events to each day) without hitting
    SQLite once per day.
    """
    local_tz = datetime.now().astimezone().tzinfo
    day_keys = []
    for d in range(num_days):
        day_date = (start_date + timedelta(days=d)).astimezone(local_tz).date()
        day_keys.append(day_date)
    totals: dict = {k: 0.0 for k in day_keys}
    first_key = day_keys[0]
    last_key = day_keys[-1]

    for ev in events:
        if ev["duration"] <= 0:
            continue
        remaining = ev["duration"]
        cursor = ev["timestamp_utc"]
        for _ in range(num_days + 2):
            if remaining <= 0:
                break
            local_day = cursor.astimezone(local_tz).date()
            next_midnight = (
                datetime.combine(local_day, datetime.min.time(), tzinfo=local_tz)
                + timedelta(days=1)
            )
            span = (next_midnight - cursor).total_seconds()
            if span <= 0:
                break
            chunk = min(remaining, span)
            if first_key <= local_day <= last_key:
                totals[local_day] += chunk
            remaining -= chunk
            cursor = next_midnight
    return totals


def cmd_month() -> dict:
    local_tz = datetime.now().astimezone().tzinfo
    now_local = datetime.now().astimezone()
    today_start = now_local.replace(hour=0, minute=0, second=0, microsecond=0)

    # Trailing 365 days for heatmap + monthly stats, in one query.
    year_start = today_start - timedelta(days=364)
    start_ns = _to_ns(year_start.astimezone(timezone.utc))
    end_ns = _to_ns((today_start + timedelta(days=1)).astimezone(timezone.utc))
    year_events = _active_events(start_ns, end_ns)
    daily = _daily_totals(year_events, year_start, 365)

    # Build heatmap grid (weeks as columns, Sun..Sat top to bottom)
    grid_end_date = today_start.date()
    grid_start_date = year_start.date()
    # Shift back to the Sunday that starts that week
    grid_start_date = grid_start_date - timedelta(days=(grid_start_date.weekday() + 1) % 7)

    num_weeks = ((grid_end_date - grid_start_date).days + 6) // 7 + 1

    heatmap: list[list[int]] = []
    month_labels: list[list] = []
    last_month = ""

    for week_idx in range(num_weeks):
        week_col: list[int] = []
        for day_idx in range(7):  # Sun=0 .. Sat=6
            cell_date = grid_start_date + timedelta(weeks=week_idx, days=day_idx)
            if cell_date > grid_end_date:
                week_col.append(-1)  # future / out of range
            else:
                week_col.append(int(daily.get(cell_date, 0)))
        heatmap.append(week_col)

    # Month labels
    for week_idx in range(num_weeks):
        cell_date = grid_start_date + timedelta(weeks=week_idx)
        month_name = cell_date.strftime("%b")
        if month_name != last_month:
            month_labels.append([week_idx, month_name])
            last_month = month_name

    # Monthly stats (last 30 days, incl. today)
    total_active = 0.0
    active_days = 0
    best_day: dict | None = None
    for d in range(30):
        day_date = (today_start - timedelta(days=d)).astimezone(local_tz).date()
        total = daily.get(day_date, 0.0)
        total_active += total
        if total > 0:
            active_days += 1
        if best_day is None or total > best_day["secs"]:
            best_day = {
                "date": (today_start - timedelta(days=d)).astimezone(local_tz).strftime("%a, %b %d"),
                "secs": round(total, 1),
            }

    daily_avg = total_active / active_days if active_days > 0 else 0

    # Top lists for 30-day range
    thirty_start = today_start - timedelta(days=29)
    start_ns = _to_ns(thirty_start.astimezone(timezone.utc))
    end_ns = _to_ns(today_start.astimezone(timezone.utc))
    all_categorized = _categorized_active(start_ns, end_ns)
    top_apps = _compute_top_apps(all_categorized)
    top_categories = _compute_top_categories(all_categorized)
    top_domains = _compute_top_domains(start_ns, end_ns)

    return {
        "total_active_secs": round(total_active, 1),
        "daily_avg_secs": round(daily_avg, 1),
        "active_days": active_days,
        "best_day": best_day,
        "heatmap": heatmap,
        "month_labels": month_labels,
        "top_apps": top_apps,
        "top_categories": top_categories,
        "top_domains": top_domains,
        "tracker_online": True,
    }


# ---------------------------------------------------------------------------
# JSON serialization helper (strip datetime objects)
# ---------------------------------------------------------------------------

class _Encoder(json.JSONEncoder):
    def default(self, o: Any) -> Any:
        if isinstance(o, datetime):
            return o.isoformat()
        if isinstance(o, (set, frozenset)):
            return list(o)
        return super().default(o)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Screen Time data helper")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    sub.add_parser("today")
    sub.add_parser("week")
    sub.add_parser("month")

    args = parser.parse_args()

    try:
        if args.command == "status":
            result = cmd_status()
        elif args.command == "today":
            result = cmd_today()
        elif args.command == "week":
            result = cmd_week()
        elif args.command == "month":
            result = cmd_month()
        else:
            result = {"error": "unknown command"}
    except FileNotFoundError:
        result = {
            "online": False,
            "error": "ActivityWatch database not found",
        }
    except Exception as exc:
        result = {"error": str(exc)}

    result = _bound_payload(result)
    json.dump(result, sys.stdout, cls=_Encoder, separators=(",", ":"))
    print()  # trailing newline
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
