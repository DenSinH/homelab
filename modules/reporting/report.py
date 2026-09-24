#!/usr/bin/env python3
"""Daily homelab report: InfluxDB + Loki -> HTML + plain-text e-mail.

Non-secret settings come from a JSON file (--config) merged over DEFAULTS.
Secrets come from the environment: INFLUX_TOKEN_<ORG> (org upper-cased, '-' -> '_').

Each run stores both `report-YYYYMMDD-HHMMSS.html` and `.txt` under cfg["output_dir"],
atomically re-points `latest.html`, and regenerates `index.html`.

`--index-only` skips collection and mail and only regenerates `index.html`.
"""
import argparse
import csv
import html
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime

from jinja2 import Environment


OK, INFO, WARN, CRIT = 0, 1, 2, 3
NAMES = {OK: "OK", INFO: "INFO", WARN: "WARN", CRIT: "CRIT"}
COLORS = {OK: "#2e7d32", INFO: "#546e7a", WARN: "#ef6c00", CRIT: "#c62828"}

BAD_ATTRS = {
    "Reallocated_Sector_Ct": "realloc",
    "Current_Pending_Sector": "pending",
    "Offline_Uncorrectable": "offline-unc",
    "Reported_Uncorrect": "reported-unc",
    "UDMA_CRC_Error_Count": "crc",
    "Spin_Retry_Count": "spin-retry",
    "End-to-End_Error": "end-to-end",
    "Runtime_Bad_Block": "bad-blocks",
    "Program_Fail_Cnt_Total": "prog-fail",
    "Erase_Fail_Count_Total": "erase-fail",
    "Reallocate_NAND_Blk_Cnt": "realloc-nand",
}
WEAR_ATTRS = (
    "Wear_Leveling_Count",
    "Media_Wearout_Indicator",
    "Percent_Lifetime_Remain",
    "SSD_Life_Left",
    "Percent_Life_Remaining",
)
SMART_EXIT_FLAGS = {
    16: (
        CRIT,
        "a pre-fail attribute is at or below its threshold",
        "pre-fail attribute",
    ),
    32: (
        INFO,
        "an attribute was at or below its threshold in the past",
        "past threshold",
    ),
    128: (WARN, "the self-test log contains errors", "self-test errors"),
}

DEFAULTS = {
    "influx_url": "http://localhost:8086",
    "loki_url": "http://localhost:3100",
    "grafana_url": "http://telemetry.home:3000/d/advzc6f/kiosk"
    "?orgId=1&from=now-6h&to=now&timezone=browser&refresh=5s",
    "report_url": "",
    "output_dir": "/var/lib/reports",
    "expected_stopped": [],
    "known_removed": [],
    "thresholds": {
        "reboot_hours": 24,
        "stale_minutes": 30,
        "disk_warn": 80,
        "disk_crit": 90,
        "mem_warn": 90,
        "storage_warn": 80,
        "storage_crit": 90,
        "temp_warn": 50,
        "temp_crit": 60,
        "nvme_temp_warn": 65,
        "nvme_temp_crit": 75,
        "nvme_wear_warn": 80,
        "node_cpu_warn": 80,
        "node_cpu_crit": 95,
        "node_mem_warn": 80,
        "node_mem_crit": 95,
        "zfs_frag_warn": 50,
        # How stale a device's SMART data may be before the "Last check"
        # column in the SMART table is flagged and a finding is emitted.
        "smart_stale_hours": 6,
    },
    "timers": {
        "sanoid.timer": 26,
        "syncoid-tank-drive.timer": 26,
        "syncoid-tank-photos.timer": 26,
        "zfs-scrub.timer": 24 * 35,
    },
    "log_ignore": [],
    "logs": {
        "sources": 10,
        "templates_per_source": 3,
        "sample": 500,
        "message_chars": 200,
        # Loki label that identifies a log source within a host (systemd "unit" by
        # default; set to "job" if your Loki uses the job label instead).
        "source_label": "unit",
        # Hosts that are expected to send logs.  Any of these that produces zero
        # lines in the last 24 h is listed with 0 and flagged as a warning.
        # Only list hosts that are supposed to be running and logging.
        "expected_hosts": [],
    },
    "gatus_host": "gatus",
    "energy": {
        "energy_entity": "server_plug_summation_delivered",
        "power_entity": "server_plug_power",
        "label": "Server plug",
    },
}


# ----------------------------------------------------------------------------- data model
@dataclass(frozen=True)
class Finding:
    level: int
    where: str
    text: str


@dataclass(frozen=True)
class Cell:
    text: str
    color: str | None = None


@dataclass(frozen=True)
class Table:
    headers: tuple[str, ...]
    rows: tuple[tuple[Cell, ...], ...]
    align: tuple[str, ...] = ()
    mono: tuple[bool, ...] = ()


@dataclass(frozen=True)
class Section:
    title: str
    blocks: tuple[object, ...]


class Report:
    """Mutable accumulator of findings and sections.

    The individual items are frozen dataclasses; only the two lists grow.
    """

    def __init__(self) -> None:
        self.findings: list[Finding] = []
        self.sections: list[Section] = []

    def add(self, level: int, where: str, text: str) -> None:
        self.findings.append(Finding(level, where, text))

    def section(self, title: str, *blocks: object) -> None:
        kept = tuple(b for b in blocks if b)
        if kept:
            self.sections.append(Section(title, kept))


# ----------------------------------------------------------------------------- helpers
def load_config(path):
    cfg = json.loads(json.dumps(DEFAULTS))
    if path:
        with open(path) as f:
            user = json.load(f)
        for key, value in user.items():
            if isinstance(value, dict) and isinstance(cfg.get(key), dict):
                cfg[key].update(value)
            else:
                cfg[key] = value
    return cfg


def num(value, default=None):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def pct(used, total):
    return 100.0 * used / total if total else 0.0


def lvl(value, warn, crit=None):
    if crit is not None and value >= crit:
        return CRIT
    return WARN if value >= warn else OK


def fmt_dur(seconds):
    d, rem = divmod(int(seconds), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m}m"
    return f"{m}m"


def fmt_bytes(b):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(b) < 1024 or unit == "TiB":
            return f"{b:.0f} B" if unit == "B" else f"{b:.1f} {unit}"
        b /= 1024


def clip(text, n):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _cell(value) -> Cell:
    if isinstance(value, tuple):
        text, level = value
    else:
        text, level = value, OK
    return Cell(str(text), COLORS[level] if level >= WARN else None)


_ALIGN_MAP = {"l": "left", "r": "right", "c": "center"}


def _align_tuple(spec, n):
    if spec is None:
        return ("left",) * n
    if isinstance(spec, str):
        spec = spec.ljust(n, "l")[:n]
        return tuple(_ALIGN_MAP.get(ch, "left") for ch in spec)
    spec = tuple(spec)
    return spec + ("left",) * (n - len(spec))


def _mono_tuple(spec, n):
    if spec is None:
        return (False,) * n
    if isinstance(spec, str):
        spec = spec.ljust(n, " ")
        return tuple(ch == "m" for ch in spec)
    spec = tuple(bool(x) for x in spec)
    return spec + (False,) * (n - len(spec))


def table(headers, rows, align=None, mono=None) -> Table | None:
    """Build a Table. `align` is e.g. "llrr" (left/right per column); `mono` is
    e.g. "mm.." (m = monospace, anything else = proportional). Cell values may
    be plain strings, or (text, level) tuples to colour the cell.
    Returns None if there is nothing to render."""
    if not rows:
        return None
    n = len(headers)
    return Table(
        headers=tuple(headers),
        rows=tuple(tuple(_cell(c) for c in row) for row in rows),
        align=_align_tuple(align, n),
        mono=_mono_tuple(mono, n),
    )


# Plain-text rendering, used only by the text/plain alternative in the e-mail.
def text_table(t: Table) -> str:
    cols = [[h for h in t.headers]] + [[c.text for c in row] for row in t.rows]
    widths = [max(len(str(x[i])) for x in cols) for i in range(len(t.headers))]

    def fmt(cells):
        parts = []
        for text, w, al in zip(cells, widths, t.align):
            s = str(text)
            parts.append(s.rjust(w) if al == "right" else s.ljust(w))
        return "  ".join(parts).rstrip()

    out = [fmt(t.headers), fmt(["-" * w for w in widths])]
    out += [fmt([c.text for c in row]) for row in t.rows]
    return "\n".join(out)


_HTML_TAG = re.compile(r"<[^>]+>")


def strip_html(s: str) -> str:
    return html.unescape(_HTML_TAG.sub("", s)).strip()


# ----------------------------------------------------------------------------- data sources
def parse_csv(text):
    rows, header = [], None
    for rec in csv.reader(io.StringIO(text.replace("\r", ""))):
        if not rec or all(c == "" for c in rec):
            header = None
            continue
        if rec[0].startswith("#"):
            continue
        if header is None:
            header = rec
            continue
        rows.append(dict(zip(header, rec)))
    if rows and "error" in rows[0] and "result" not in rows[0]:
        raise RuntimeError(f"flux error: {rows[0]['error']}")
    return rows


class Influx:
    def __init__(self, url):
        self.url = url.rstrip("/")

    def query(self, org, flux):
        token = os.environ.get("INFLUX_TOKEN_" + org.upper().replace("-", "_"))
        if not token:
            raise RuntimeError(f"no INFLUX_TOKEN_* in environment for org {org}")
        req = urllib.request.Request(
            f"{self.url}/api/v2/query?org={urllib.parse.quote(org)}",
            data=flux.encode(),
            headers={
                "Authorization": f"Token {token}",
                "Content-Type": "application/vnd.flux",
                "Accept": "application/csv",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return parse_csv(resp.read().decode())
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"influx {org}: HTTP {e.code} {e.read().decode()[:300]}"
            ) from None


class Loki:
    def __init__(self, url):
        self.url = url.rstrip("/")

    def _get(self, path, **params):
        req = urllib.request.Request(
            f"{self.url}{path}?{urllib.parse.urlencode(params)}"
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            raise RuntimeError(
                f"loki HTTP {e.code}: {e.read().decode()[:300]}"
            ) from None

    def instant(self, query):
        data = self._get("/loki/api/v1/query", query=query)
        return [(r["metric"], float(r["value"][1])) for r in data["data"]["result"]]

    def lines(self, selector, limit):
        """Newest `limit` lines of the last 24 h, newest first: [(timestamp_ns, line), ...]."""
        data = self._get(
            "/loki/api/v1/query_range", query=selector, limit=limit, since="24h"
        )
        out = [
            (int(ts), line) for s in data["data"]["result"] for ts, line in s["values"]
        ]
        return sorted(out, reverse=True)


def flux_values(bucket, measurement, fields, tags, agg="last", since="-10m", where=""):
    record = ", ".join(
        [f"{t}: r.{t}" for t in tags]
        + ["field: r._field", "value: string(v: r._value)"]
    )
    return (
        f'from(bucket: "{bucket}")\n'
        f"  |> range(start: {since})\n"
        f'  |> filter(fn: (r) => r._measurement == "{measurement}"{where})\n'
        f"  |> filter(fn: (r) => contains(value: r._field, set: {json.dumps(fields)}))\n"
        f"  |> {agg}()\n"
        f"  |> map(fn: (r) => ({{{record}}}))\n"
        f"  |> group()\n"
    )


def pivot(rows, keys):
    out = {}
    for r in rows:
        out.setdefault(tuple(r.get(k, "") for k in keys), {})[r["field"]] = r["value"]
    return out


def metric(influx, org, measurement, tags, agg="last", since="-10m", where=""):
    rows = influx.query(
        org,
        flux_values(
            org, measurement, ["gauge", "counter", "value"], tags, agg, since, where
        ),
    )
    return [({t: r.get(t, "") for t in tags}, num(r["value"])) for r in rows]


# ----------------------------------------------------------------------------- logs (errors first)
_NORMALIZE = [
    (re.compile(r"\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b", re.I), "<uuid>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "<ip>"),
    (re.compile(r"\b0x[0-9a-f]+\b", re.I), "<hex>"),
    (re.compile(r"\b[0-9a-f]{12,}\b", re.I), "<hex>"),
    (re.compile(r"\d+"), "<n>"),
]


def normalize(line):
    for rx, repl in _NORMALIZE:
        line = rx.sub(repl, line)
    return " ".join(line.split())


def summarize(lines):
    """Group newest-first (ts, line) pairs by template: [{n, last, example}, ...], most frequent first."""
    groups = {}
    for ts, line in lines:
        g = groups.setdefault(normalize(line), {"n": 0, "last": ts, "example": line})
        g["n"] += 1
    return sorted(groups.values(), key=lambda g: -g["n"])


def _fmt_delta(cur, prev):
    """Returns (text, level) for the 'vs previous' cell."""
    if cur == 0 and prev == 0:
        return ("—", OK)
    if not prev:
        return ("new", INFO)
    ratio = cur / prev
    level = WARN if (ratio > 3 or ratio < 0.1) and max(cur, prev) >= 100 else OK
    return (f"{100 * (cur - prev) / prev:+.0f}%", level)


def log_errors_section(cfg, loki, rep):
    """Error-level log lines in the last 24 h: per-host totals, then the top
    templates per host/source. Rendered first in the report."""
    L = cfg["logs"]
    label = L["source_label"]
    err = '| detected_level=~"error|critical|fatal"'
    sel = '{host=~".+"}'

    err_cur = {
        m.get("host", "?"): v
        for m, v in loki.instant(f"sum by (host) (count_over_time({sel} {err} [24h]))")
    }
    err_prev = {
        m.get("host", "?"): v
        for m, v in loki.instant(
            f"sum by (host) (count_over_time({sel} {err} [24h] offset 24h))"
        )
    }
    for host, n in sorted(err_cur.items(), key=lambda kv: -kv[1]):
        p = err_prev.get(host, 0)
        if n >= 20 and n >= 3 * max(p, 1):
            rep.add(
                WARN,
                "Logs",
                f"{host}: {int(n)} error lines in 24 h (previous 24 h: {int(p)})",
            )

    total = int(sum(err_cur.values()))
    rep.add(
        INFO,
        "Logs",
        f"{total} error-level log lines across {len(err_cur)} hosts in 24 h",
    )

    if not err_cur:
        rep.section(
            "Log errors (last 24 h)",
            "<p>No error-level log lines in the last 24 hours.</p>",
        )
        return

    top_err = loki.instant(
        f"topk({2 * L['sources']}, sum by (host, {label}) (count_over_time({sel} {err} [24h])))"
    )
    ignore = [re.compile(p) for p in cfg["log_ignore"]]
    rows, hidden, sampled, sources = [], 0, False, 0
    for m, n in sorted(top_err, key=lambda kv: -kv[1]):
        host, unit = m.get("host", "?"), m.get(label, "")
        name = f"{host}/{unit or 'kernel/other'}"
        lines = loki.lines(f'{{host="{host}", {label}="{unit}"}} {err}', L["sample"])
        groups = summarize(lines)
        shown = [
            g
            for g in groups
            if not any(rx.search(f"{name} {g['example']}") for rx in ignore)
        ]
        hidden += len(groups) - len(shown)
        if not shown:
            continue
        sampled = sampled or n > len(lines)
        for i, g in enumerate(shown[: L["templates_per_source"]]):
            rows.append(
                [
                    f"{name} ({int(n)})" if i == 0 else "",
                    g["n"],
                    f"{datetime.fromtimestamp(g['last'] / 1e9):%H:%M}",
                    clip(g["example"], L["message_chars"]),
                ]
            )
        extra = len(shown) - L["templates_per_source"]
        if extra > 0:
            rows.append(
                [
                    "",
                    "",
                    "",
                    f"+ {extra} more distinct message{'s' if extra > 1 else ''}",
                ]
            )
        sources += 1
        if sources == L["sources"]:
            break
    notes = []
    if sampled:
        notes.append(
            f"Per-message counts come from the newest {L['sample']} lines of each source; "
            f"the number after the source is its 24 h total."
        )
    if hidden:
        notes.append(f"{hidden} distinct messages hidden by log_ignore.")
    note = "".join(
        f'<p style="font-size:12px;color:#777;margin:2px 0">{html.escape(x)}</p>'
        for x in notes
    )
    rep.section(
        "Log errors (last 24 h)",
        table(
            ["Source (24 h errors)", "Count", "Last", "Message"],
            rows,
            align="lrrl",
            mono="m...",
        ),
        note,
    )


def log_volume_section(cfg, loki, rep):
    """Total log volume per host + top producers per host/source."""
    L = cfg["logs"]
    label = L["source_label"]
    sel = '{host=~".+"}'

    vol_cur = {
        m.get("host", "?"): v
        for m, v in loki.instant(f"sum by (host) (count_over_time({sel} [24h]))")
    }
    vol_prev = {
        m.get("host", "?"): v
        for m, v in loki.instant(
            f"sum by (host) (count_over_time({sel} [24h] offset 24h))"
        )
    }

    # Hosts we expect to see in Loki.  A host counts as present if Loki has
    # either its full name (proxmox1.home) or the short form (proxmox1); both
    # are common depending on how the log shipper derives the `host` label.
    # A host that sent nothing is listed once, under its FQDN, as an INFO note.
    expected = list(L.get("expected_hosts", []))

    def short(name):
        return name.split(".", maxsplit=1)[0]

    loki_hosts = set(vol_cur.keys())
    claimed = {exp for exp in expected if exp in loki_hosts or short(exp) in loki_hosts}
    silent = [exp for exp in expected if exp not in claimed]
    for host in silent:
        vol_cur[host] = 0.0
        rep.add(INFO, "Logs", f"{host}: expected to send logs but sent none in 24 h")

    # Hosts that went quiet (previous volume collapsed) — skip the ones we just
    # flagged so we don't add two findings for the same host.
    for host, p in vol_prev.items():
        if host in silent:
            continue
        c = vol_cur.get(host, 0)
        if p >= 100 and c < p / 100:
            rep.add(
                WARN,
                "Logs",
                f"{host}: only {int(c)} log lines in 24 h (previous: {int(p)}) — still sending?",
            )

    volume_rows = []
    for host, n in sorted(vol_cur.items(), key=lambda kv: -kv[1]):
        volume_rows.append([host, f"{int(n):,}", _fmt_delta(n, vol_prev.get(host, 0))])
    volume_tbl = table(
        ["Host", "Lines (24 h)", "vs previous"], volume_rows, align="lrr", mono="m.."
    )

    top = loki.instant(
        f"topk({2 * L['sources']}, sum by (host, {label}) (count_over_time({sel} [24h])))"
    )
    producer_rows = []
    for m, n in sorted(top, key=lambda kv: -kv[1])[: 2 * L["sources"]]:
        host, unit = m.get("host", "?"), m.get(label, "")
        producer_rows.append([f"{host}/{unit or 'kernel/other'}", f"{int(n):,}"])
    producer_tbl = table(
        [f"Top producers (host / {label})", "Lines (24 h)"],
        producer_rows,
        align="lr",
        mono="m.",
    )

    rep.section("Log volume (last 24 h)", volume_tbl, producer_tbl)


# ----------------------------------------------------------------------------- Proxmox + PBS
def proxmox_section(cfg, influx, rep):
    org, sec, T = "proxmox", "Proxmox", cfg["thresholds"]
    now = time.time()
    reboot_s = T["reboot_hours"] * 3600

    guests = pivot(
        influx.query(
            org,
            flux_values(
                org,
                "system",
                ["status", "uptime", "mem", "maxmem", "disk", "maxdisk"],
                ["host", "nodename", "object"],
                where=' and (r.object == "lxc" or r.object == "qemu")',
            ),
        ),
        ["host", "nodename", "object"],
    )
    running = stopped_ok = 0
    disks = []
    for (name, node, kind), f in sorted(guests.items()):
        status = f.get("status", "?")
        if status != "running":
            if name in cfg["expected_stopped"]:
                stopped_ok += 1
            else:
                rep.add(CRIT, sec, f"{kind} {name} ({node}) is {status}")
            continue
        running += 1
        up = num(f.get("uptime"), 0)
        if up < reboot_s:
            rep.add(INFO, sec, f"{name} restarted {fmt_dur(up)} ago")
        if kind == "lxc":
            mem, maxmem = num(f.get("mem")), num(f.get("maxmem"))
            if mem is not None and maxmem and pct(mem, maxmem) >= T["mem_warn"]:
                rep.add(
                    WARN,
                    sec,
                    f"{name}: memory at {pct(mem, maxmem):.0f}% of {fmt_bytes(maxmem)}",
                )
            disk, maxdisk = num(f.get("disk")), num(f.get("maxdisk"))
            if disk is not None and maxdisk:
                p = pct(disk, maxdisk)
                disks.append((p, name, node, disk, maxdisk))
                level = lvl(p, T["disk_warn"], T["disk_crit"])
                if level:
                    rep.add(
                        level,
                        sec,
                        f"{name}: root disk at {p:.0f}% of {fmt_bytes(maxdisk)}",
                    )
    disks.sort(reverse=True)
    summary = f"<p>{running} guests running, {stopped_ok} stopped as expected.</p>"
    disk_tbl = table(
        ["Fullest LXC disks", "Node", "Used", "%"],
        [
            [
                n,
                node,
                f"{fmt_bytes(d)} / {fmt_bytes(m)}",
                (f"{p:.0f}%", lvl(p, T["disk_warn"], T["disk_crit"])),
            ]
            for p, n, node, d, m in disks[:6]
        ],
        align="llrr",
        mono="mm..",
    )

    stale = influx.query(
        org,
        (
            f'from(bucket: "{org}")\n'
            f"  |> range(start: -7d)\n"
            f'  |> filter(fn: (r) => r._measurement == "system" and r._field == "uptime")\n'
            f"  |> last()\n"
            f"  |> map(fn: (r) => ({{host: r.host, object: r.object, t: string(v: uint(v: r._time))}}))\n"
            f"  |> group()\n"
        ),
    )
    for r in stale:
        age = now - int(r["t"]) / 1e9
        if age > T["stale_minutes"] * 60 and r["host"] not in cfg["known_removed"]:
            rep.add(
                WARN,
                sec,
                f"{r['object']} {r['host']} has sent no metrics for {fmt_dur(age)}",
            )

    up = pivot(
        influx.query(
            org,
            flux_values(
                org, "system", ["uptime"], ["host"], where=' and r.object == "nodes"'
            ),
        ),
        ["host"],
    )
    cpu = pivot(
        influx.query(
            org,
            flux_values(
                org,
                "cpustat",
                ["cpu"],
                ["host"],
                agg="mean",
                since="-24h",
                where=' and r.object == "nodes"',
            ),
        ),
        ["host"],
    )
    mem = pivot(
        influx.query(
            org,
            flux_values(
                org,
                "memory",
                ["memused", "memtotal"],
                ["host"],
                where=' and r.object == "nodes"',
            ),
        ),
        ["host"],
    )
    node_rows = []
    for (node,), f in sorted(up.items()):
        u = num(f.get("uptime"), 0)
        if u < reboot_s:
            rep.add(WARN, sec, f"node {node} rebooted {fmt_dur(u)} ago")
        c = num(cpu.get((node,), {}).get("cpu"))
        m = mem.get((node,), {})
        mp = (
            pct(num(m.get("memused"), 0), num(m.get("memtotal"), 0))
            if m.get("memtotal")
            else None
        )
        c_level = (
            lvl(100 * c, T["node_cpu_warn"], T["node_cpu_crit"])
            if c is not None
            else OK
        )
        m_level = (
            lvl(mp, T["node_mem_warn"], T["node_mem_crit"]) if mp is not None else OK
        )
        node_rows.append(
            [
                node,
                fmt_dur(u),
                (f"{100 * c:.0f}%", c_level) if c is not None else "n/a",
                (f"{mp:.0f}%", m_level) if mp is not None else "n/a",
            ]
        )
    node_tbl = table(
        ["Node", "Uptime", "CPU avg 24h", "Memory"],
        node_rows,
        align="lrrr",
        mono="m...",
    )

    # storages (sorted by usage %, highest first)
    st = pivot(
        influx.query(
            org,
            flux_values(
                org,
                "system",
                ["total", "used", "type", "shared"],
                ["host", "nodename"],
                where=' and r.object == "storages"',
            ),
        ),
        ["host", "nodename"],
    )
    seen, st_data = set(), []
    for (name, node), f in sorted(st.items()):
        total, used = num(f.get("total")), num(f.get("used"))
        if not total:
            continue
        if f.get("shared") == "1":
            if name in seen:
                continue
            seen.add(name)
            node = "shared"
        p = pct(used, total)
        level = lvl(p, T["storage_warn"], T["storage_crit"])
        if level:
            rep.add(level, sec, f"storage {name} ({node}) is {p:.0f}% full")
        st_data.append((p, name, node, f.get("type", ""), used, total, level))
    st_data.sort(key=lambda x: -x[0])
    st_tbl = table(
        ["Storage", "Node", "Type", "Used", "%"],
        [
            [name, node, typ, f"{fmt_bytes(u)} / {fmt_bytes(t)}", (f"{p:.0f}%", lvl_)]
            for p, name, node, typ, u, t, lvl_ in st_data
        ],
        align="lllrr",
        mono="mm...",
    )

    # PBS datastores (sorted by usage %, highest first)
    ds = pivot(
        influx.query(
            org,
            flux_values(
                org,
                "blockstat",
                ["total", "used"],
                ["host", "datastore"],
                where=' and (exists r.datastore) and r.datastore != ""',
            ),
        ),
        ["host", "datastore"],
    )
    ds_data = []
    for (host, store), f in sorted(ds.items()):
        total, used = num(f.get("total")), num(f.get("used"))
        if not total:
            continue
        p = pct(used, total)
        level = lvl(p, T["storage_warn"], T["storage_crit"])
        if level:
            rep.add(level, "PBS", f"datastore {store} on {host} is {p:.0f}% full")
        ds_data.append((p, host, store, used, total, level))
    ds_data.sort(key=lambda x: -x[0])
    ds_tbl = table(
        ["PBS host", "Datastore", "Used", "%"],
        [
            [h, s, f"{fmt_bytes(u)} / {fmt_bytes(t)}", (f"{p:.0f}%", lvl_)]
            for p, h, s, u, t, lvl_ in ds_data
        ],
        align="llrr",
        mono="mm..",
    )

    rep.section("Proxmox & PBS", summary, node_tbl, st_tbl, ds_tbl, disk_tbl)


# ----------------------------------------------------------------------------- NAS / offsite (ZFS, SMART, timers)
def host_section(cfg, influx, rep, org, label):
    T, now = cfg["thresholds"], time.time()

    boot = metric(influx, org, "node_boot_time_seconds", ["host"])
    if not boot:
        rep.add(CRIT, label, "no metrics received in the last 10 minutes")
        rep.section(label, "<p>No metrics received.</p>")
        return
    load = metric(influx, org, "node_load15", ["host"])
    up = now - boot[0][1]
    if up < T["reboot_hours"] * 3600:
        rep.add(WARN, label, f"rebooted {fmt_dur(up)} ago")
    intro = (
        f"<p>Uptime {fmt_dur(up)}"
        + (f", load15 {load[0][1]:.2f}" if load else "")
        + "</p>"
    )

    state = {
        t["zpool"]: t["state"]
        for t, v in metric(influx, org, "node_zfs_zpool_state", ["zpool", "state"])
        if v and v > 0.5
    }
    size = {
        t["pool"]: v for t, v in metric(influx, org, "zfs_pool_size_bytes", ["pool"])
    }
    alloc = {
        t["pool"]: v
        for t, v in metric(influx, org, "zfs_pool_allocated_bytes", ["pool"])
    }
    frag = {
        t["pool"]: v
        for t, v in metric(influx, org, "zfs_pool_fragmentation_ratio", ["pool"])
    }
    zfs_where = ' and r.fstype == "zfs"'
    fs_size = {
        t["mountpoint"]: v
        for t, v in metric(
            influx, org, "node_filesystem_size_bytes", ["mountpoint"], where=zfs_where
        )
    }
    fs_avail = {
        t["mountpoint"]: v
        for t, v in metric(
            influx, org, "node_filesystem_avail_bytes", ["mountpoint"], where=zfs_where
        )
    }

    pool_data = []
    for pool in sorted(state):
        s = state[pool]
        if s != "online":
            rep.add(CRIT, label, f"pool {pool} is {s.upper()}")
        total, used = size.get(pool), alloc.get(pool)
        if total is None and f"/{pool}" in fs_size:
            total = fs_size[f"/{pool}"]
            used = total - fs_avail.get(f"/{pool}", 0)
        p = pct(used, total) if total else None
        level = lvl(p, T["storage_warn"], T["storage_crit"]) if p is not None else OK
        if level:
            rep.add(level, label, f"pool {pool} is {p:.0f}% full")
        fr = frag.get(pool)
        fr_pct = (fr * 100 if fr <= 1 else fr) if fr is not None else None
        fr_level = lvl(fr_pct, T["zfs_frag_warn"]) if fr_pct is not None else OK
        pool_data.append(
            (
                p if p is not None else -1.0,
                pool,
                s,
                used,
                total,
                p,
                level,
                fr_pct,
                fr_level,
            )
        )
    pool_data.sort(key=lambda x: -x[0])
    pool_tbl = table(
        ["Pool", "State", "Used", "%", "Frag"],
        [
            [
                pool,
                (s, OK if s == "online" else CRIT),
                f"{fmt_bytes(u)} / {fmt_bytes(t)}" if t else "n/a",
                (f"{p:.0f}%", level) if p is not None else "n/a",
                (f"{fp:.0f}%", fl) if fp is not None else "n/a",
            ]
            for _sort, pool, s, u, t, p, level, fp, fl in pool_data
        ],
        align="llrrr",
        mono="m....",
    )
    if not state:
        rep.add(WARN, label, "no ZFS pool state metrics found")

    # non-ZFS filesystems (sorted by usage %, highest first)
    other_where = ' and (r.fstype == "ext4" or r.fstype == "xfs" or r.fstype == "btrfs" or r.fstype == "vfat")'
    o_size = {
        t["mountpoint"]: v
        for t, v in metric(
            influx, org, "node_filesystem_size_bytes", ["mountpoint"], where=other_where
        )
    }
    o_avail = {
        t["mountpoint"]: v
        for t, v in metric(
            influx,
            org,
            "node_filesystem_avail_bytes",
            ["mountpoint"],
            where=other_where,
        )
    }
    fs_data = []
    for mount, total in sorted(o_size.items()):
        if not total or mount not in o_avail:
            continue
        used = total - o_avail[mount]
        p = pct(used, total)
        level = lvl(p, T["storage_warn"], T["storage_crit"])
        if level:
            rep.add(level, label, f"filesystem {mount} is {p:.0f}% full")
        fs_data.append((p, mount, used, total, level))
    fs_data.sort(key=lambda x: -x[0])
    fs_tbl = table(
        ["Filesystem", "Used", "%"],
        [
            [mount, f"{fmt_bytes(u)} / {fmt_bytes(t)}", (f"{p:.0f}%", lvl_)]
            for p, mount, u, t, lvl_ in fs_data
        ],
        align="lrr",
        mono="m..",
    )

    def by_dev(measurement, **kw):
        return {
            t["device"]: v
            for t, v in metric(influx, org, measurement, ["device"], **kw)
        }

    model = {
        t["device"]: t["model_name"]
        for t, _ in metric(influx, org, "smartctl_device", ["device", "model_name"])
    }
    healthy = by_dev("smartctl_device_smart_status")
    temp = by_dev(
        "smartctl_device_temperature", where=' and r.temperature_type == "current"'
    )
    poh = by_dev("smartctl_device_power_on_seconds")
    wear = by_dev("smartctl_device_percentage_used")
    spare = by_dev("smartctl_device_available_spare")
    spare_min = by_dev("smartctl_device_available_spare_threshold")
    written = by_dev("smartctl_device_bytes_written")
    crit_warn = by_dev("smartctl_device_critical_warning")
    media = by_dev("smartctl_device_media_errors")
    errlog_now = by_dev("smartctl_device_error_log_count")
    errlog_old = by_dev("smartctl_device_error_log_count", agg="first", since="-24h")
    exit_status = by_dev("smartctl_device_smartctl_exit_status")

    # Per-device SMART freshness.  Last successful write to any smartctl_device
    # series for a given device in the last 7 days; used to fill the "Last
    # check" column and to raise a finding if the exporter has gone quiet.
    last_check: dict[str, float] = {}
    for r in influx.query(
        org,
        (
            f'from(bucket: "{org}")\n'
            f"  |> range(start: -7d)\n"
            f'  |> filter(fn: (r) => r._measurement == "smartctl_device")\n'
            f"  |> last()\n"
            f"  |> map(fn: (r) => ({{device: r.device, t: string(v: uint(v: r._time))}}))\n"
            f"  |> group()\n"
        ),
    ):
        dev = r.get("device")
        if not dev:
            continue
        age = now - int(r["t"]) / 1e9
        last_check[dev] = min(age, last_check.get(dev, age))

    attrs = {}
    for t, v in metric(
        influx,
        org,
        "smartctl_device_attribute",
        ["device", "attribute_name", "attribute_value_type"],
    ):
        if v is not None:
            attrs.setdefault(t["device"], {}).setdefault(t["attribute_name"], {})[
                t["attribute_value_type"]
            ] = v
    bad_names = " or ".join(f'r.attribute_name == "{n}"' for n in BAD_ATTRS)
    old_raw = {
        (t["device"], t["attribute_name"]): v
        for t, v in metric(
            influx,
            org,
            "smartctl_device_attribute",
            ["device", "attribute_name"],
            agg="first",
            since="-24h",
            where=f' and r.attribute_value_type == "raw" and ({bad_names})',
        )
    }

    if not (healthy or model):
        rep.add(WARN, label, "no SMART metrics found")

    def short(d):
        return f"{model.get(d, '?')} [{d if d.startswith('nvme') else d[-6:]}]"

    def flag(d, errs, level, finding, cell):
        rep.add(level, label, f"{short(d)}: {finding}")
        errs.append((level, cell))

    smart_rows = []
    for d in sorted(set(healthy) | set(model)):
        nvme = d.startswith("nvme")
        dattrs = attrs.get(d, {})
        errs = []

        ok = healthy.get(d)
        if ok is not None and ok < 0.5:
            rep.add(CRIT, label, f"SMART health FAILED: {short(d)}")

        t = temp.get(d)
        tw, tc = (
            (T["nvme_temp_warn"], T["nvme_temp_crit"])
            if nvme
            else (T["temp_warn"], T["temp_crit"])
        )
        t_level = lvl(t, tw, tc) if t is not None else OK
        if t_level:
            rep.add(t_level, label, f"{short(d)} is at {t:.0f} C")

        if crit_warn.get(d):
            flag(d, errs, CRIT, "NVMe critical warning flags set", "critical warning")
        if media.get(d):
            flag(
                d,
                errs,
                WARN,
                f"{int(media[d])} NVMe media errors",
                f"media errors {int(media[d])}",
            )
        if d in spare and d in spare_min and spare[d] <= spare_min[d]:
            flag(
                d,
                errs,
                CRIT,
                f"available spare {spare[d]:.0f}% is at/below its threshold "
                f"({spare_min[d]:.0f}%)",
                "spare low",
            )
        if errlog_now.get(d) is not None and errlog_now[d] > (errlog_old.get(d) or 0):
            flag(
                d,
                errs,
                WARN,
                f"SMART error log grew to {int(errlog_now[d])}",
                f"error log {int(errlog_now[d])}",
            )

        # SMART check freshness for this device
        age = last_check.get(d)
        if age is None:
            check_cell = ("never", WARN)
            rep.add(WARN, label, f"{short(d)}: no SMART data in the last 7 days")
        else:
            check_level = lvl(age / 3600, T["smart_stale_hours"])
            if check_level >= WARN:
                rep.add(
                    check_level,
                    label,
                    f"{short(d)}: SMART last checked {fmt_dur(age)} ago",
                )
            check_cell = (f"{fmt_dur(age)} ago", check_level)

        for name, abbr in BAD_ATTRS.items():
            raw = dattrs.get(name, {}).get("raw")
            if raw and raw > 0:
                grew = raw - (old_raw.get((d, name)) or 0)
                flag(
                    d,
                    errs,
                    CRIT if grew > 0 else WARN,
                    f"{name} = {int(raw)}"
                    + (f" (+{int(grew)} in 24h)" if grew > 0 else ""),
                    f"{abbr} {int(raw)}",
                )
        for name, a in dattrs.items():
            v, th = a.get("value"), a.get("thresh")
            if v is not None and th and v <= th:
                flag(
                    d,
                    errs,
                    CRIT,
                    f"{name} normalised value {v:.0f} is at/below its failure "
                    f"threshold {th:.0f}",
                    f"{name} at threshold",
                )

        code = int(exit_status.get(d) or 0)
        for bit, (level, finding, cell) in SMART_EXIT_FLAGS.items():
            if code & bit:
                flag(d, errs, level, finding, cell)

        w = wear.get(d)
        if w is None:
            for name in WEAR_ATTRS:
                v = dattrs.get(name, {}).get("value")
                if v is not None:
                    w = 100 - v
                    break
        w_level = lvl(w, T["nvme_wear_warn"]) if w is not None else OK
        if w_level:
            rep.add(w_level, label, f"{short(d)}: {w:.0f}% of endurance used")
        wear_text = ""
        if w is not None:
            wear_text = f"{w:.0f}% used" + (
                f", spare {spare[d]:.0f}%" if d in spare else ""
            )

        smart_rows.append(
            [
                short(d),
                (
                    ("n/a", OK)
                    if ok is None
                    else ("PASSED", OK) if ok >= 0.5 else ("FAILED", CRIT)
                ),
                (f"{t:.0f} C", t_level) if t is not None else "n/a",
                f"{poh[d] / 86400:.0f} d" if d in poh else "n/a",
                check_cell,
                (wear_text, w_level) if wear_text else "",
                fmt_bytes(written[d]) if d in written else "",
                (
                    (", ".join(x for _, x in errs), max(l for l, _ in errs))
                    if errs
                    else "none"
                ),
            ]
        )
    smart_tbl = table(
        [
            "Disk",
            "Health",
            "Temp",
            "Power-on",
            "Last check",
            "Wear",
            "Written",
            "Errors",
        ],
        smart_rows,
        align="llrrrrrl",
        mono="m.......",
    )

    trig = {
        t["name"]: v
        for t, v in metric(
            influx, org, "node_systemd_timer_last_trigger_seconds", ["name"]
        )
    }
    timer_rows = []
    for name, max_h in cfg["timers"].items():
        if name not in trig:
            continue
        v = trig[name]
        if not v:
            if up < max_h * 3600:
                rep.add(
                    INFO, label, f"{name} has not fired since boot {fmt_dur(up)} ago"
                )
                timer_rows.append([name, f"not since boot ({fmt_dur(up)} ago)"])
            else:
                rep.add(
                    WARN, label, f"{name} has not fired since boot {fmt_dur(up)} ago"
                )
                timer_rows.append([name, ("never since boot", WARN)])
            continue
        age_h = (now - v) / 3600
        level = WARN if age_h > max_h else OK
        if level:
            rep.add(
                WARN,
                label,
                f"{name} last fired {fmt_dur(now - v)} ago (limit {max_h} h)",
            )
        timer_rows.append([name, (f"{fmt_dur(now - v)} ago", level)])
    timer_tbl = table(["Timer", "Last run"], timer_rows, align="lr", mono="m.")

    for t, v in metric(
        influx,
        org,
        "node_systemd_unit_state",
        ["name"],
        where=' and r.state == "failed"',
    ):
        if v and v > 0.5:
            rep.add(CRIT, label, f"systemd unit {t['name']} is failed")

    rep.section(label, intro, pool_tbl, fs_tbl, smart_tbl, timer_tbl)


# ----------------------------------------------------------------------------- energy
def energy_section(cfg, influx, rep):
    e, org = cfg["energy"], "homeassistant"

    def one(measurement, entity, agg):
        rows = metric(
            influx,
            org,
            measurement,
            ["entity_id"],
            agg=agg,
            since="-24h",
            where=f' and r.entity_id == "{entity}"',
        )
        return rows[0][1] if rows else None

    first = one("kWh", e["energy_entity"], "first")
    last = one("kWh", e["energy_entity"], "last")
    avg_w = one("W", e["power_entity"], "mean")
    peak_w = one("W", e["power_entity"], "max")
    if last is None or first is None:
        rep.add(
            WARN,
            "Energy",
            f"no {e['label']} readings in the last 24 hours (Home Assistant down?)",
        )
        return
    used = last - first
    text = f"{e['label']}: {used:.2f} kWh in the last 24 h"
    if avg_w is not None and peak_w is not None:
        text += f" (avg {avg_w:.0f} W, peak {peak_w:.0f} W)"
    rep.add(INFO, "Energy", text)
    rep.section("Energy", f"<p>{html.escape(text)}</p>")


# ----------------------------------------------------------------------------- gatus
def gatus_section(cfg, loki, rep):
    base = '{host="%s"}' % cfg["gatus_host"]
    rx = '| regexp "endpoint=(?P<endpoint>[^;]+);"'
    fail = {
        m["endpoint"]: v
        for m, v in loki.instant(
            f'sum by (endpoint) (count_over_time({base} |= "success=false" {rx} [24h]))'
        )
    }
    total = {
        m["endpoint"]: v
        for m, v in loki.instant(
            f'sum by (endpoint) (count_over_time({base} |= "executeEndpoint" {rx} [24h]))'
        )
    }
    if not total:
        rep.add(WARN, "Gatus", "no gatus check results found in Loki for the last 24 h")
        return
    rows = []
    for ep, n in sorted(fail.items(), key=lambda kv: -kv[1]):
        t = total.get(ep, n)
        ratio = n / t if t else 1.0
        level = CRIT if ratio >= 0.5 else WARN if ratio >= 0.05 else INFO
        if level >= WARN:
            rep.add(
                level,
                "Gatus",
                f"{ep}: {int(n)} of {int(t)} checks failed in 24 h ({ratio:.0%})",
            )
        rows.append([ep, int(n), int(t), (f"{ratio:.0%}", level)])
    msg = "" if rows else f"<p>All {len(total)} endpoints passed every check.</p>"
    rep.section(
        "Service checks (Gatus)",
        table(
            ["Endpoint", "Failed", "Checks", "Failure rate"],
            rows,
            align="lrrr",
            mono="m...",
        ),
        msg,
    )


# ----------------------------------------------------------------------------- output
def load_template(path, filters=None):
    try:
        with open(path) as f:
            source = f.read()
    except OSError as e:
        sys.exit(f"error: cannot read template {path}: {e}")
    env = Environment(autoescape=True)
    if filters:
        env.filters.update(filters)
    return env.from_string(source)


def render(cfg, rep, html_template, text_template, started):
    counts = {
        lv: sum(1 for f in rep.findings if f.level == lv) for lv in (CRIT, WARN, INFO)
    }
    if counts[CRIT]:
        status, headline = "CRIT", f"{counts[CRIT]} critical, {counts[WARN]} warnings"
    elif counts[WARN]:
        status, headline = "WARN", f"{counts[WARN]} warnings"
    else:
        status, headline = "OK", "All systems normal"
    now = datetime.now().astimezone()
    subject = f"[{status}] Homelab report {now:%d %b}: {headline}"
    elapsed = time.monotonic() - started
    duration = f"{elapsed:.1f}s" if elapsed < 60 else fmt_dur(elapsed)
    ctx = dict(
        status=status,
        subject=subject,
        status_color=COLORS[{"CRIT": CRIT, "WARN": WARN, "OK": OK}[status]],
        headline=headline,
        timestamp=f"{now:%a %d %b %Y %H:%M}",
        critical=[(f.where, f.text) for f in rep.findings if f.level == CRIT],
        warnings=[(f.where, f.text) for f in rep.findings if f.level == WARN],
        notes=[f.text for f in rep.findings if f.level == INFO],
        sections=rep.sections,
        grafana_url=cfg["grafana_url"],
        report_url=cfg.get("report_url", ""),
        duration=duration,
        crit_color=COLORS[CRIT],
        warn_color=COLORS[WARN],
        info_color=COLORS[INFO],
    )
    return status, subject, html_template.render(**ctx), text_template.render(**ctx)


def save_report(cfg, body_html, body_text):
    """Write the HTML and text bodies under one timestamped name, then atomically
    repoint latest.html. Returns (html_name, html_path, text_path)."""
    out = cfg["output_dir"]
    os.makedirs(out, exist_ok=True)
    stamp = f"{datetime.now():%Y%m%d-%H%M%S}"
    html_name = f"report-{stamp}.html"
    html_path = os.path.join(out, html_name)
    text_path = os.path.join(out, f"report-{stamp}.txt")
    for path, body in ((html_path, body_html), (text_path, body_text)):
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write(body)
        os.replace(tmp, path)

    link = os.path.join(out, "latest.html")
    tmp_link = link + ".tmp"
    if os.path.lexists(tmp_link):
        os.unlink(tmp_link)
    os.symlink(html_name, tmp_link)
    os.replace(tmp_link, link)
    return html_name, html_path, text_path


def write_index(cfg, template):
    out = cfg["output_dir"]
    os.makedirs(out, exist_ok=True)
    reports = []
    for name in os.listdir(out):
        m = re.match(r"report-(\d{8})-(\d{6})\.html$", name)
        if not m:
            continue
        full = os.path.join(out, name)
        if not os.path.isfile(full):
            continue
        try:
            dt = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S")
        except ValueError:
            continue
        status = "?"
        try:
            with open(full) as f:
                head = f.read(1024)
            sm = re.search(r"report-status:\s*(\w+)", head)
            if sm:
                status = sm.group(1)
        except OSError:
            pass
        color = COLORS[{"OK": OK, "WARN": WARN, "CRIT": CRIT}.get(status, INFO)]
        reports.append(
            {
                "name": name,
                "time": dt.strftime("%a %d %b %Y %H:%M"),
                "status": status,
                "color": color if status in ("WARN", "CRIT") else None,
            }
        )
    reports.sort(key=lambda r: r["name"], reverse=True)
    body = template.render(reports=reports)
    path = os.path.join(out, "index.html")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.replace(tmp, path)


def guarded(rep, name, fn, *args):
    try:
        fn(*args)
    except Exception as e:  # keep the report going; the failure shows up as a warning
        rep.add(WARN, "report", f"{name} collector failed: {type(e).__name__}: {e}")


def discover(influx, org, prefix):
    """Print which metrics exist in an org, to check the names the collectors expect."""
    schema = 'import "influxdata/influxdb/schema"\n'
    names = sorted(
        r["_value"]
        for r in influx.query(org, schema + f'schema.measurements(bucket: "{org}")')
    )
    print(f"measurements in {org} starting with '{prefix}':")
    for n in names:
        if n.startswith(prefix):
            print(f"  {n}")
    if "smartctl_device_attribute" in names:
        rows = influx.query(
            org,
            schema
            + (
                f'schema.tagValues(bucket: "{org}", tag: "attribute_name", start: -1d, '
                f'predicate: (r) => r._measurement == "smartctl_device_attribute")'
            ),
        )
        print("SMART attributes: " + ", ".join(sorted(r["_value"] for r in rows)))


def main():
    started = time.monotonic()
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--config")
    ap.add_argument(
        "--template", required=True, help="Jinja2 template for the HTML report"
    )
    ap.add_argument(
        "--text-template",
        required=True,
        help="Jinja2 template for the plain-text report",
    )
    ap.add_argument(
        "--index-template", required=True, help="Jinja2 template for the index page"
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="write the report but do not send it by e-mail",
    )
    ap.add_argument(
        "--index-only",
        action="store_true",
        help="only regenerate index.html and exit (no collection, no mail)",
    )
    ap.add_argument(
        "--discover",
        metavar="ORG",
        help="list the metrics available in an InfluxDB org and exit",
    )
    ap.add_argument(
        "--prefix",
        default="smartctl",
        help="measurement prefix for --discover (default: smartctl)",
    )
    args = ap.parse_args()

    cfg = load_config(args.config)
    index_template = load_template(args.index_template)

    if args.index_only:
        write_index(cfg, index_template)
        print(f"index written to {os.path.join(cfg['output_dir'], 'index.html')}")
        return

    influx, loki = Influx(cfg["influx_url"]), Loki(cfg["loki_url"])
    if args.discover:
        discover(influx, args.discover, args.prefix)
        return

    rep = Report()
    # log errors first so they show up at the top of the body
    guarded(rep, "log-errors", log_errors_section, cfg, loki, rep)
    guarded(rep, "log-volume", log_volume_section, cfg, loki, rep)
    guarded(rep, "proxmox", proxmox_section, cfg, influx, rep)
    guarded(rep, "nas", host_section, cfg, influx, rep, "nas", "NAS")
    guarded(
        rep,
        "offsite",
        host_section,
        cfg,
        influx,
        rep,
        "offsite-backup",
        "Offsite backup host",
    )
    guarded(rep, "energy", energy_section, cfg, influx, rep)
    guarded(rep, "gatus", gatus_section, cfg, loki, rep)

    html_template = load_template(args.template)
    text_template = load_template(
        args.text_template, filters={"text_table": text_table, "strip_html": strip_html}
    )
    status, subject, body_html, body_text = render(
        cfg, rep, html_template, text_template, started
    )

    _name, html_path, text_path = save_report(cfg, body_html, body_text)
    write_index(cfg, index_template)
    print(f"report saved to {html_path}")

    if args.dry_run:
        print(subject)
        for f in sorted(rep.findings, key=lambda f: -f.level):
            print(f"  {NAMES[f.level]:<4} {f.where}: {f.text}")
        return

    result = subprocess.run(
        ["send-mail", "--html", "--text-file", text_path, "--subject", subject],
        input=body_html.encode(),
    )
    if result.returncode:
        sys.exit(f"send-mail failed (exit code {result.returncode})")


if __name__ == "__main__":
    sys.exit(main())
