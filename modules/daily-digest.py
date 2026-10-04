#!/usr/bin/env python3
"""daily-digest.py — build the morning digest page. See modules/daily-digest.nix.

Usage: daily-digest.py --config FILE {weekday|weekend|today} [--out DIR] [--no-llm]

The slot argument is which timer fired, or `today` for a manual rebuild. Each run decides for itself whether
today is a workday (weekends and holidays are not), and does nothing when the
slot does not match: the weekday timer is a no-op on a holiday and the weekend
timer is a no-op on a workday. That keeps the holiday calendar in ONE place —
here — and Home Assistant only relays whatever this wrote.

Every section degrades on its own. A dead feed, CalDAV outage, Yahoo change or
Claude failure becomes a line in `problems`, which is printed on the page and
in the push, rather than failing the run: a digest with a hole in it is more
useful at 07:45 than no digest. The run exits non-zero only when it could not
write the page at all, which is what OnFailure reports.
"""

import argparse
import datetime as dt
import html
import json
import logging
import os
import re
import sys
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

import anthropic
import caldav
import feedparser
import holidays
import recurring_ical_events

log = logging.getLogger("daily-digest")

# NWS asks for an identifying User-Agent. A repo URL, never a personal address.
NWS_UA = "homelab-daily-digest (https://github.com/bcrescimanno/homelab-nix)"
# Yahoo's chart endpoint rejects obvious non-browser agents.
YAHOO_UA = "Mozilla/5.0 (X11; Linux aarch64) homelab-daily-digest"
HTTP_TIMEOUT = 20


def http_get(url, ua, accept="*/*"):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Accept": accept})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        return resp.read()


def http_json(url, ua, accept="application/json"):
    return json.loads(http_get(url, ua, accept))


# ---------------------------------------------------------------------------
# Day classification
# ---------------------------------------------------------------------------

def day_kind(day, cfg):
    """'weekend' for Saturdays, Sundays and holidays; 'weekday' otherwise."""
    if day.weekday() >= 5:
        return "weekend"
    hcfg = cfg["holidays"]
    if day.isoformat() in hcfg.get("extra", []):
        return "weekend"
    # Only the holidays named in `observe` count; python-holidays lists every
    # federal holiday. A name matches itself and its "(observed)" variant —
    # never a substring, or "Independence Day" would also match "Juneteenth
    # National Independence Day". `adjacent` adds days relative to a holiday
    # whose date moves (the days around Thanksgiving). Neighbouring years are
    # included so an offset can cross New Year.
    def named(name, wanted):
        return name == wanted or name.startswith(wanted + " (")

    calendar = holidays.country_holidays(
        hcfg["country"], years=[day.year - 1, day.year, day.year + 1]
    )
    for date, name in calendar.items():
        if date == day and any(named(name, o) for o in hcfg["observe"]):
            return "weekend"
        for holiday, offsets in hcfg.get("adjacent", {}).items():
            if named(name, holiday) and any(date + dt.timedelta(days=o) == day for o in offsets):
                return "weekend"
    return "weekday"


# ---------------------------------------------------------------------------
# Weather (NWS)
# ---------------------------------------------------------------------------

def fetch_weather(cfg, today):
    wcfg = cfg["weather"]
    fc = http_json(
        f"https://api.weather.gov/gridpoints/{wcfg['gridpoint']}/forecast",
        NWS_UA, "application/geo+json",
    )
    periods = fc["properties"]["periods"]

    def start_date(p):
        return dt.datetime.fromisoformat(p["startTime"]).date()

    # The daytime period for today ("Today", or the weekday name). Fall back to
    # whatever comes first if the run is late enough that NWS has moved on.
    day_idx = next(
        (i for i, p in enumerate(periods) if p["isDaytime"] and start_date(p) == today),
        0,
    )
    day = periods[day_idx]
    night = next((p for p in periods[day_idx + 1:] if not p["isDaytime"]), None)

    out = {
        "name": day["name"],
        "short": day["shortForecast"],
        "detail": day["detailedForecast"],
        "high": day["temperature"] if day["isDaytime"] else None,
        "low": night["temperature"] if night else None,
        "pop": (day.get("probabilityOfPrecipitation") or {}).get("value"),
        "now": None,
    }

    # Current conditions are a nice-to-have; never fail the section over them.
    try:
        obs = http_json(
            f"https://api.weather.gov/stations/{wcfg['station']}/observations/latest",
            NWS_UA, "application/geo+json",
        )["properties"]
        age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(obs["timestamp"])
        temp_c = (obs.get("temperature") or {}).get("value")
        if temp_c is not None and age < dt.timedelta(hours=2):
            out["now"] = {
                "temp": round(temp_c * 9 / 5 + 32),
                "text": obs.get("textDescription") or "",
            }
    except Exception:
        log.warning("current observation unavailable", exc_info=True)
    return out


# ---------------------------------------------------------------------------
# Calendars (CalDAV)
# ---------------------------------------------------------------------------

def _local(value, tz):
    """Normalise a DTSTART/DTEND value: dates stay dates, datetimes go local."""
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:  # floating time: it means local
            return value.replace(tzinfo=tz)
        return value.astimezone(tz)
    return value


def fetch_calendars(cfg, today, tz, problems):
    day_start = dt.datetime.combine(today, dt.time.min, tzinfo=tz)
    day_end = day_start + dt.timedelta(days=1)
    events = []

    for source in cfg["calendars"]:
        if source["type"] != "caldav":
            raise ValueError(f"unknown calendar source type {source['type']!r}")
        client = caldav.DAVClient(
            url=source["url"],
            username=os.environ[source["usernameEnv"]],
            password=os.environ[source["passwordEnv"]],
            timeout=HTTP_TIMEOUT,
        )
        by_name = {}
        for cal in client.principal().calendars():
            by_name[(cal.get_display_name() or "").strip()] = cal

        for name in source["names"]:
            cal = by_name.get(name)
            if cal is None:
                log.error("calendar %r not found; server has: %s", name, sorted(by_name))
                problems.append(f"Calendar “{name}” not found")
                continue
            seen = set()
            # No server-side expansion: iCloud's is unreliable, so fetch the
            # objects that overlap today and expand recurrences locally.
            for obj in cal.search(event=True, start=day_start, end=day_end):
                for comp in recurring_ical_events.of(obj.icalendar_instance).between(
                    day_start, day_end
                ):
                    start = _local(comp.decoded("DTSTART"), tz)
                    end = _local(comp.decoded("DTEND"), tz) if "DTEND" in comp else None
                    key = (str(comp.get("UID")), str(start))
                    if key in seen:
                        continue
                    seen.add(key)
                    all_day = not isinstance(start, dt.datetime)
                    events.append({
                        "calendar": name,
                        "title": str(comp.get("SUMMARY", "(no title)")),
                        "location": str(comp.get("LOCATION", "") or ""),
                        "all_day": all_day,
                        "start": start,
                        "end": end,
                    })

    def sort_key(e):
        if e["all_day"]:
            return (0, dt.time.min, e["title"])
        return (1, e["start"].time(), e["title"])

    events.sort(key=sort_key)
    return events


# ---------------------------------------------------------------------------
# Chores (Home Assistant's sensor.chores — see modules/ha-chores.nix)
# ---------------------------------------------------------------------------

def fetch_chores(cfg):
    ccfg = cfg["chores"]
    req = urllib.request.Request(ccfg["url"], headers={
        "Authorization": f"Bearer {os.environ[ccfg['tokenEnv']]}",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
        state = json.loads(resp.read())
    # The sensor latches over its sources' outages, so its own state is only
    # unavailable when the template itself is broken. That is a problem, not
    # an empty list.
    chores = state.get("attributes", {}).get("chores")
    if state.get("state") in ("unavailable", "unknown") or not isinstance(chores, list):
        raise ValueError(f"sensor.chores is {state.get('state')!r}")
    return [str(c) for c in chores]


# ---------------------------------------------------------------------------
# Markets (Yahoo chart endpoint — unofficial, keyless)
# ---------------------------------------------------------------------------

def fetch_quote(symbol):
    url = (
        "https://query1.finance.yahoo.com/v8/finance/chart/"
        f"{urllib.parse.quote(symbol)}?range=1d&interval=1d"
    )
    meta = http_json(url, YAHOO_UA)["chart"]["result"][0]["meta"]
    price = meta["regularMarketPrice"]
    # With range=1d, chartPreviousClose is the prior session's close. With a
    # wider range it is the close before the RANGE, which is not a day change.
    prev = meta["chartPreviousClose"]
    return {
        "symbol": symbol,
        "price": price,
        "change": price - prev,
        "pct": (price - prev) / prev * 100 if prev else 0.0,
        "time": meta.get("regularMarketTime"),
    }


def fetch_markets(cfg, problems):
    rows, failed = [], []
    entries = [(i["symbol"], i["name"]) for i in cfg["markets"]["indexes"]]
    entries += [(t, t) for t in cfg["markets"]["tickers"]]
    for symbol, label in entries:
        try:
            q = fetch_quote(symbol)
            q["label"] = label
            rows.append(q)
        except Exception:
            log.warning("quote failed for %s", symbol, exc_info=True)
            failed.append(label)
    if failed:
        problems.append(
            "Market data unavailable" if not rows else f"No quote for {', '.join(failed)}"
        )
    return rows


# ---------------------------------------------------------------------------
# News (RSS → Claude)
# ---------------------------------------------------------------------------

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")


def clean(text, limit=None):
    text = WS_RE.sub(" ", html.unescape(TAG_RE.sub(" ", text or ""))).strip()
    if limit and len(text) > limit:
        text = text[: limit - 1].rstrip() + "…"
    return text


def fetch_candidates(cfg, problems):
    """Every recent item from every feed, keyed by a short stable id."""
    ncfg = cfg["news"]
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=ncfg["maxAgeHours"])
    candidates, seen_links = {}, set()

    for section in ncfg["sections"]:
        n = 0
        for feed in section["feeds"]:
            parsed = None
            for attempt in (1, 2):  # one retry; feeds time out transiently
                try:
                    parsed = feedparser.parse(http_get(feed["url"], YAHOO_UA))
                    if parsed.bozo and not parsed.entries:
                        raise ValueError(parsed.bozo_exception)
                    break
                except Exception as exc:
                    log.warning("feed attempt %d failed: %s: %s", attempt, feed["url"], exc)
                    parsed = None
            if parsed is None:
                problems.append(f"Feed unavailable: {feed['name']}")
                continue
            kept = 0
            for entry in parsed.entries:
                if kept >= ncfg["perFeed"]:
                    break
                link = entry.get("link")
                title = clean(entry.get("title"))
                if not link or not title or link in seen_links:
                    continue
                stamp = entry.get("published_parsed") or entry.get("updated_parsed")
                if stamp:
                    when = dt.datetime(*stamp[:6], tzinfo=dt.timezone.utc)
                    if when < cutoff:
                        continue
                seen_links.add(link)
                n += 1
                kept += 1
                candidates[f"{section['id']}{n}"] = {
                    "section": section["id"],
                    "source": feed["name"],
                    "title": title,
                    "description": clean(entry.get("summary"), 400),
                    "link": link,
                }
    return candidates


def build_system_prompt(cfg):
    ncfg = cfg["news"]
    sections = ", ".join(f"{s['id']} ({s['title']})" for s in ncfg["sections"])
    excluded = "\n".join(f"- {e}" for e in ncfg["exclude"])
    return f"""You are the editor of a personal morning news digest for one reader.
The reader wants a short, serious briefing: what actually happened that matters,
in a mix of US, world and technology news.

You will receive candidate items from RSS feeds as JSON, keyed by id. Each has a
section ({sections}), a source, a title and usually a short description.

For each section, choose up to {ncfg['itemsPerSection']} items from THAT section's
candidates and write a summary for each.

Never choose items about:
{excluded}

Selection rules:
- Prefer consequential, substantive stories over routine announcements. Daily
  security-update lists, stable point releases and "weekly roundup" posts are
  low priority unless nothing better exists.
- One story appears once in the whole digest. When several outlets cover the
  same story, pick the item with the most informative description.
- If a section has fewer than {ncfg['itemsPerSection']} acceptable items, return
  fewer. Never pad with excluded topics.
- Order each section most important first.

Summary rules:
- One or two plain sentences, at most 40 words, neutral in tone.
- Use only facts present in the item's title and description. Do not add
  context, numbers or names from your own knowledge. If the description is
  empty, restate the headline plainly rather than guessing.
- No clickbait, no editorializing, no "this article discusses"."""


def summarize_news(cfg, candidates):
    ncfg = cfg["news"]
    section_ids = [s["id"] for s in ncfg["sections"]]
    item = {
        "type": "object",
        "properties": {"id": {"type": "string"}, "summary": {"type": "string"}},
        "required": ["id", "summary"],
        "additionalProperties": False,
    }
    schema = {
        "type": "object",
        "properties": {sid: {"type": "array", "items": item} for sid in section_ids},
        "required": section_ids,
        "additionalProperties": False,
    }
    # The model sees ids, never has to reproduce URLs; links are mapped back
    # from the id below, so a summary can never point at an invented link.
    payload = {
        cid: {k: c[k] for k in ("section", "source", "title", "description")}
        for cid, c in candidates.items()
    }

    client = anthropic.Anthropic(timeout=300.0, max_retries=3)
    response = client.beta.messages.create(
        model=ncfg["model"],
        max_tokens=16000,
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        output_config={
            "effort": ncfg["effort"],
            "format": {"type": "json_schema", "schema": schema},
        },
        system=build_system_prompt(cfg),
        messages=[{"role": "user", "content": json.dumps(payload, ensure_ascii=False)}],
    )
    if response.stop_reason != "end_turn":
        raise RuntimeError(f"Claude stopped with {response.stop_reason!r}")
    text = next(b.text for b in response.content if b.type == "text")
    picked = json.loads(text)
    log.info(
        "claude: model=%s in=%s out=%s",
        response.model, response.usage.input_tokens, response.usage.output_tokens,
    )

    result, used = {}, set()
    for sid in section_ids:
        result[sid] = []
        for choice in picked.get(sid, []):
            cid = choice["id"]
            c = candidates.get(cid)
            # Drop anything that is not a real candidate of this section, or a
            # repeat. Claude is told the rules; this enforces them.
            if c is None or c["section"] != sid or cid in used:
                log.warning("discarding invalid pick %r for %s", cid, sid)
                continue
            used.add(cid)
            result[sid].append({**c, "summary": choice["summary"].strip()})
            if len(result[sid]) >= ncfg["itemsPerSection"]:
                break
    return result


def unsummarized_news(cfg, candidates):
    """Fallback when Claude is unavailable: the newest items, round-robin by
    source so one prolific feed cannot fill a section. NOT filtered."""
    ncfg = cfg["news"]
    result = {}
    for section in ncfg["sections"]:
        by_source = {}
        for c in candidates.values():
            if c["section"] == section["id"]:
                by_source.setdefault(c["source"], []).append(c)
        picks, queues = [], list(by_source.values())
        while queues and len(picks) < ncfg["itemsPerSection"]:
            for q in list(queues):
                if q and len(picks) < ncfg["itemsPerSection"]:
                    picks.append({**q.pop(0), "summary": ""})
                if not q:
                    queues.remove(q)
        for p in picks:
            p["summary"] = clean(p["description"], 200)
        result[section["id"]] = picks
    return result


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def fmt_time(t):
    return t.strftime("%-I:%M %p").replace(":00 ", " ")


def describe_event(e, today):
    if e["all_day"]:
        when = "All day"
        if e["end"] and isinstance(e["end"], dt.date) and (e["end"] - e["start"]).days > 1:
            last = e["end"] - dt.timedelta(days=1)  # DTEND is exclusive for dates
            if last > today:
                when = f"All day · through {last.strftime('%a %b %-d')}"
    else:
        when = fmt_time(e["start"])
        if e["end"] and isinstance(e["end"], dt.datetime):
            when += f"–{fmt_time(e['end'])}"
    return when


def push_message(weather, events, chores, markets, problems):
    parts = []
    if weather:
        w = weather["short"]
        if weather["high"] is not None and weather["low"] is not None:
            w += f", {weather['high']}°/{weather['low']}°"
        parts.append(w)
    if events is not None:
        timed = [e for e in events if not e["all_day"]]
        if not events:
            parts.append("Nothing on the calendar")
        elif timed:
            parts.append(
                f"{len(events)} on the calendar, first at {fmt_time(timed[0]['start'])}"
            )
        else:
            parts.append(f"{len(events)} all-day on the calendar")
    if chores:
        parts.append(f"{len(chores)} chore{'s' if len(chores) > 1 else ''}")
    spx = next((m for m in markets or [] if m["symbol"] == "^GSPC"), None)
    if spx:
        parts.append(f"S&P {spx['pct']:+.1f}%")
    msg = " · ".join(parts) or "Your digest is ready"
    if problems:
        msg += f"\n⚠ {len(problems)} problem{'s' if len(problems) > 1 else ''}"
    return msg


CSS = """
:root{--bg:#f6f5f2;--card:#fff;--fg:#1d1d1f;--muted:#6b6b70;--line:#e4e2dd;
--accent:#2f5d8a;--up:#1f7a3f;--down:#b3261e;--warn-bg:#fff4d6;--warn-fg:#6b4e00}
@media (prefers-color-scheme:dark){:root{--bg:#121214;--card:#1c1c1f;--fg:#ececee;
--muted:#9a9aa1;--line:#2c2c31;--accent:#8db7e3;--up:#6fcf8f;--down:#ff8a80;
--warn-bg:#3a2f12;--warn-fg:#f5d77a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
main{max-width:720px;margin:0 auto;padding:24px 16px 48px}
header h1{margin:0;font-size:1.6rem;letter-spacing:-.01em}
header p{margin:2px 0 0;color:var(--muted)}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:16px 18px;margin-top:16px}
h2{margin:0 0 10px;font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted)}
.warn{background:var(--warn-bg);color:var(--warn-fg);border-color:transparent}
.warn ul{margin:0;padding-left:18px}
.wx-top{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
.wx-temp{font-size:1.9rem;font-weight:600}
.wx-short{font-size:1.1rem}
.muted{color:var(--muted)}
.small{font-size:.9rem}
ul.events,ul.news,ul.chores{list-style:none;margin:0;padding:0}
ul.chores li{padding:6px 0;border-top:1px solid var(--line)}
ul.chores li:first-child{border-top:0;padding-top:0}
ul.events li{display:flex;gap:12px;padding:8px 0;border-top:1px solid var(--line)}
ul.events li:first-child{border-top:0;padding-top:0}
.when{flex:0 0 7.5rem;color:var(--muted);font-variant-numeric:tabular-nums}
.tag{font-size:.75rem;color:var(--muted);border:1px solid var(--line);border-radius:6px;
padding:0 6px;margin-left:6px;white-space:nowrap}
table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
td{padding:6px 0;border-top:1px solid var(--line)}
tr:first-child td{border-top:0}
td.num{text-align:right}
.up{color:var(--up)}.down{color:var(--down)}
ul.news li{padding:14px 0;border-top:1px solid var(--line)}
ul.news li:first-child{border-top:0;padding-top:0}
ul.news a{color:var(--fg);font-size:1.25rem;line-height:1.3;font-weight:650;
letter-spacing:-.01em;text-decoration:none}
ul.news a:hover{color:var(--accent);text-decoration:underline}
ul.news p{margin:6px 0 0}
.src{font-size:.8rem;color:var(--muted);margin-top:2px}
footer{margin-top:24px;color:var(--muted);font-size:.8rem;text-align:center}
@media (max-width:480px){.when{flex-basis:5.5rem}}
"""


def render_html(ctx):
    e = html.escape
    today = ctx["today"]
    out = [
        "<!doctype html><html lang=en><head><meta charset=utf-8>",
        '<meta name=viewport content="width=device-width,initial-scale=1">',
        f"<title>Daily Digest · {e(today.strftime('%a %b %-d'))}</title>",
        f"<style>{CSS}</style></head><body><main>",
        f"<header><h1>{e(today.strftime('%A, %B %-d'))}</h1>",
        f"<p>Good morning.</p></header>",
    ]

    if ctx["problems"]:
        out.append('<section class="warn"><h2>Problems</h2><ul>')
        out += [f"<li>{e(p)}</li>" for p in ctx["problems"]]
        out.append("</ul></section>")

    w = ctx["weather"]
    if w:
        out.append("<section><h2>Weather</h2><div class=wx-top>")
        if w["high"] is not None:
            low = f" / {w['low']}°" if w["low"] is not None else ""
            out.append(f"<span class=wx-temp>{w['high']}°{low}</span>")
        out.append(f"<span class=wx-short>{e(w['short'])}</span></div>")
        out.append(f"<p class=small>{e(w['detail'])}</p>")
        extra = []
        if w["now"]:
            extra.append(f"Now {w['now']['temp']}° {w['now']['text']}".strip())
        if w["pop"]:
            extra.append(f"{w['pop']}% chance of rain")
        if extra:
            out.append(f"<p class='small muted'>{e(' · '.join(extra))}</p>")
        out.append("</section>")

    if ctx["events"] is not None:
        out.append("<section><h2>Today</h2>")
        if not ctx["events"]:
            out.append("<p class=muted>Nothing on the calendar.</p>")
        else:
            out.append("<ul class=events>")
            for ev in ctx["events"]:
                loc = f"<div class='small muted'>{e(ev['location'])}</div>" if ev["location"] else ""
                out.append(
                    f"<li><span class=when>{e(describe_event(ev, today))}</span>"
                    f"<span>{e(ev['title'])}<span class=tag>{e(ev['calendar'])}</span>{loc}</span></li>"
                )
            out.append("</ul>")
        out.append("</section>")

    if ctx["chores"] is not None:
        out.append("<section><h2>Chores</h2>")
        if not ctx["chores"]:
            out.append("<p class=muted>Nothing to do.</p>")
        else:
            out.append("<ul class=chores>")
            out += [f"<li>{e(c)}</li>" for c in ctx["chores"]]
            out.append("</ul>")
        out.append("</section>")

    if ctx["markets"]:
        out.append("<section><h2>Markets</h2><table>")
        for m in ctx["markets"]:
            cls = "up" if m["change"] >= 0 else "down"
            out.append(
                f"<tr><td>{e(m['label'])}</td><td class=num>{m['price']:,.2f}</td>"
                f"<td class='num {cls}'>{m['change']:+,.2f}</td>"
                f"<td class='num {cls}'>{m['pct']:+.2f}%</td></tr>"
            )
        out.append("</table>")
        stamp = max((m["time"] or 0) for m in ctx["markets"])
        if stamp:
            asof = dt.datetime.fromtimestamp(stamp, ctx["tz"])
            label = fmt_time(asof)
            if asof.date() != today:
                label = f"{asof.strftime('%a')} {label}"
            out.append(f"<p class='small muted'>As of {e(label)}</p>")
        out.append("</section>")

    for section in ctx["sections"]:
        items = ctx["news"].get(section["id"], [])
        out.append(f"<section><h2>{e(section['title'])}</h2>")
        if not items:
            out.append("<p class=muted>No stories.</p>")
        else:
            out.append("<ul class=news>")
            for it in items:
                summary = f"<p>{e(it['summary'])}</p>" if it["summary"] else ""
                out.append(
                    f"<li><a href='{e(it['link'])}'>{e(it['title'])}</a>"
                    f"<div class=src>{e(it['source'])}</div>{summary}</li>"
                )
            out.append("</ul>")
        out.append("</section>")

    gen = ctx["generated_at"]
    out.append(
        f"<footer>Generated {e(gen.strftime('%a %b %-d'))} at {e(fmt_time(gen))}"
        " · modules/daily-digest.nix</footer></main></body></html>"
    )
    return "\n".join(out)


def write_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    # mkstemp creates 0600, and the mode survives the rename. Caddy and Home
    # Assistant read these as other users.
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def guarded(problems, label, fn, *args):
    try:
        return fn(*args)
    except Exception:
        log.exception("%s failed", label)
        problems.append(f"{label} unavailable")
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("slot", choices=["weekday", "weekend", "today"])
    ap.add_argument("--config", required=True)
    ap.add_argument("--out", help="override the output directory (testing)")
    ap.add_argument("--no-llm", action="store_true", help="skip Claude (testing)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    # caldav warns when iCloud's iCalendar text differs from its re-serialized
    # form (a trailing space in a SUMMARY is enough) and the warning carries a
    # diff of the WHOLE EVENT. Calendar contents do not belong in the journal.
    # Filtered at the handler: caldav.lib.error calls setLevel(WARNING) on the
    # "caldav" logger when it is lazily imported, which overrides any level set
    # here first.
    for handler in logging.getLogger().handlers:
        handler.addFilter(
            lambda r: not (r.name.startswith("caldav") and r.levelno < logging.ERROR)
        )

    cfg = json.loads(Path(args.config).read_text())
    tz = ZoneInfo(cfg["timezone"])
    now = dt.datetime.now(tz)
    today = now.date()
    kind = day_kind(today, cfg)
    if args.slot not in (kind, "today"):
        log.info("%s is a %s; nothing to do for the %s slot", today, kind, args.slot)
        return 0

    problems = []
    weather = guarded(problems, "Weather", fetch_weather, cfg, today)
    events = guarded(problems, "Calendar", fetch_calendars, cfg, today, tz, problems)
    chores = guarded(problems, "Chores", fetch_chores, cfg)
    # Stocks are a workday thing; markets are closed on most of these days anyway.
    markets = fetch_markets(cfg, problems) if kind == "weekday" else None

    candidates = guarded(problems, "News", fetch_candidates, cfg, problems) or {}
    news = {}
    if candidates:
        if args.no_llm:
            news = unsummarized_news(cfg, candidates)
        else:
            try:
                news = summarize_news(cfg, candidates)
            except Exception:
                log.exception("Claude summarization failed")
                problems.append("News not summarized or filtered (Claude unavailable)")
                news = unsummarized_news(cfg, candidates)

    ctx = {
        "today": today,
        "tz": tz,
        "generated_at": dt.datetime.now(tz),
        "problems": problems,
        "weather": weather,
        "events": events,
        "chores": chores,
        "markets": markets,
        "news": news,
        "sections": cfg["news"]["sections"],
    }
    out_dir = Path(args.out or cfg["outputDir"])
    write_atomic(out_dir / "index.html", render_html(ctx))
    # Written LAST: Home Assistant pushes when this names today, so it must
    # never announce a page that is not on disk yet.
    write_atomic(out_dir / "latest.json", json.dumps({
        "date": today.isoformat(),
        "slot": kind,
        "generated_at": ctx["generated_at"].isoformat(),
        "url": cfg["url"],
        "push_title": f"Daily Digest · {today.strftime('%A, %B %-d')}",
        "push_message": push_message(weather, events, chores, markets, problems),
        "problems": problems,
    }, ensure_ascii=False, indent=2))
    log.info("wrote digest for %s (%s) with %d problem(s)", today, kind, len(problems))
    return 0


if __name__ == "__main__":
    sys.exit(main())
