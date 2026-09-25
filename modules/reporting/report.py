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
from collections.abc import Callable, Sequence
from dataclasses import dataclass, fields
from datetime import datetime
from typing import TypeVar

from jinja2 import Environment, Template


OK, INFO, WARN, CRIT = 0, 1, 2, 3
NAMES = {OK: "OK", INFO: "INFO", WARN: "WARN", CRIT: "CRIT"}
COLORS = {OK: "#2e7d32", INFO: "#546e7a", WARN: "#ef6c00", CRIT: "#c62828"}
# Overall report/run status is only ever one of these three (never INFO).
STATUS_LEVEL = {"OK": OK, "WARN": WARN, "CRIT": CRIT}

# Loaded config: DEFAULTS deep-merged with the optional --config JSON file.
Config = dict[str, object]
# One parsed InfluxDB annotated-CSV row.
CsvRow = dict[str, str]

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
    # Standalone hosts to run host_section() for, e.g. [{"org": "nas", "label": "NAS"}].
    # Each needs its own InfluxDB org/bucket fed by node_exporter + smartctl_exporter +
    # zfs_exporter. Proxmox-managed guests/nodes don't go here -- proxmox_section()
    # discovers those directly from the `proxmox` org.
    "hosts": [],
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
        # How stale a device's SMART data may be before the "Checked"
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
    """One OK/INFO/WARN/CRIT-leveled line item surfaced in the report."""

    level: int
    where: str
    text: str


@dataclass(frozen=True)
class Cell:
    """One table cell: its rendered text plus an optional highlight color."""

    text: str
    color: str | None = None


@dataclass(frozen=True)
class Table:
    """A rendered table: headers and rows of Cells, with per-column alignment/monospace/width."""

    headers: tuple[str, ...]
    rows: tuple[tuple[Cell, ...], ...]
    align: tuple[str, ...] = ()
    mono: tuple[bool, ...] = ()
    # Percentage width per column for the HTML output (sums to ~100), derived from
    # how much text that column actually holds -- see _column_widths().
    widths: tuple[float, ...] = ()
    # True for columns that only ever hold a short, single-token value (a
    # percentage, a byte size, a state word...): the HTML output keeps those from
    # ever breaking mid-value, even if the column ends up narrower than the text.
    # On narrow screens, a `nowrap` column also gets a rotated header instead of a
    # horizontal one -- see report.html.j2, which uses a CSS :has() selector to
    # rotate *every* header in a table the moment any one column needs it, so a
    # table never ends up with some headers rotated and others not.
    nowrap: tuple[bool, ...] = ()


@dataclass(frozen=True)
class Section:
    """A titled group of blocks (HTML snippets or Tables) in the report body."""

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
        """Record a finding."""
        self.findings.append(Finding(level, where, text))

    def section(self, title: str, *blocks: object) -> None:
        """Add a section, dropping falsy blocks; adds nothing if none remain."""
        kept = tuple(b for b in blocks if b)
        if kept:
            self.sections.append(Section(title, kept))


# ----------------------------------------------------------------------------- helpers
def load_config(path: str | None) -> Config:
    """Return DEFAULTS deep-copied and merged (one level deep) with the JSON file at `path`."""
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


def num(value: object, default: float | None = None) -> float | None:
    """Best-effort float conversion; returns `default` if `value` isn't numeric."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def pct(used: float | None, total: float | None) -> float:
    """Percentage `used` is of `total`, or 0.0 if `total` is falsy."""
    return 100.0 * used / total if total else 0.0


def lvl(value: float, warn: float, crit: float | None = None) -> int:
    """OK/WARN/CRIT threshold check: CRIT if value >= crit, WARN if value >= warn, else OK."""
    if crit is not None and value >= crit:
        return CRIT
    return WARN if value >= warn else OK


def fmt_dur(seconds: float) -> str:
    """Format a duration as e.g. "2d 3h", "3h 12m" or "5m"."""
    d, rem = divmod(int(seconds), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m}m"
    return f"{m}m"


def fmt_dur_short(seconds: float) -> str:
    """Single-unit duration for narrow table cells, e.g. "2d", "3h", "12m" -- the
    precise fmt_dur() is still used in finding text, where the room isn't tight."""
    d, rem = divmod(int(seconds), 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d"
    if h:
        return f"{h}h"
    return f"{m}m"


# U+00A0: keeps a number and its unit together on one line in the HTML report
NBSP = "\u00a0"


def fmt_bytes(b: float) -> str:
    """Format a byte count using binary units, e.g. "1.5 GiB" (joined by NBSP so
    the number and unit can't be split across a line break in the HTML report)."""
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        # scale down until it fits the unit, or we've hit the largest one we support
        if abs(b) < 1024 or unit == "TiB":
            return f"{b:.0f}{NBSP}B" if unit == "B" else f"{b:.1f}{NBSP}{unit}"
        b /= 1024


def clip(text: str, n: int) -> str:
    """Collapse whitespace and truncate to at most `n` characters, adding an ellipsis if cut."""
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _cell(value: object) -> Cell:
    """Build a Cell from a plain value, or from a (text, level) tuple to colour it.

    Colouring only happens for an explicit tuple, at any level including OK (so a
    good status like a passed health check reads as green, not just bad ones as
    orange/red) -- a bare value is just a label and stays in the default text colour.
    """
    if isinstance(value, tuple):
        text, level = value
        return Cell(str(text), COLORS[level])
    return Cell(str(value))


_ALIGN_MAP = {"l": "left", "r": "right", "c": "center"}


def _align_tuple(spec: str | Sequence[str] | None, n: int) -> tuple[str, ...]:
    """Expand an align spec (see `table`) to an `n`-long tuple of left/right/center."""
    if spec is None:
        return ("left",) * n
    if isinstance(spec, str):
        spec = spec.ljust(n, "l")[:n]
        return tuple(_ALIGN_MAP.get(ch, "left") for ch in spec)
    spec = tuple(spec)
    return spec + ("left",) * (n - len(spec))


def _bool_tuple(
    spec: str | Sequence[bool] | None, n: int, marker: str
) -> tuple[bool, ...]:
    """Expand a per-column boolean spec (e.g. `table`'s `mono`/`nowrap`) to an `n`-long tuple."""
    if spec is None:
        return (False,) * n
    if isinstance(spec, str):
        spec = spec.ljust(n, " ")
        return tuple(ch == marker for ch in spec)
    spec = tuple(bool(x) for x in spec)
    return spec + (False,) * (n - len(spec))


# A column's rendered width is proportional to how much text it actually holds
# (header or cell, whichever is longer), capped so that one column with far
# longer content than the rest -- a clipped log message, an error list -- can't
# squeeze every other column down to nothing.
_MAX_COLUMN_CHARS = 24

# Even a column with 1-2 characters of content (a checkmark, a short count)
# still needs real pixels for its padding and font -- pure proportional sizing
# gives it a sliver of a percent, which is not enough. No column drops below this.
_MIN_COLUMN_PERCENT = 9.0


def _column_widths(
    headers: Sequence[str], rows: Sequence[Sequence[Cell]], nowrap: Sequence[bool]
) -> tuple[float, ...]:
    """Percentage width per column (sums to 100), from actual header/cell text length.

    A `nowrap` column gets its rotated header (see the HTML template) instead of
    a horizontal one, so its header no longer needs to be counted against the
    column's *width* -- only the cell text does, which is what actually decides
    how narrow that column can be.
    """
    lengths = [
        min(
            (
                max(1, max(len(row[i].text) for row in rows))
                if nowrap[i]
                else max([len(h)] + [len(row[i].text) for row in rows])
            ),
            _MAX_COLUMN_CHARS,
        )
        for i, h in enumerate(headers)
    ]
    total = sum(lengths)
    raw = [100 * n / total for n in lengths]

    # Bring every column up to the floor, taking the space back out of columns
    # that are above it -- proportionally to how far above it they are, so the
    # column(s) that actually need the extra room keep the most of it.
    room_above_floor = [max(0.0, p - _MIN_COLUMN_PERCENT) for p in raw]
    shortfall = sum(_MIN_COLUMN_PERCENT - p for p in raw if p < _MIN_COLUMN_PERCENT)
    pool = sum(room_above_floor) or 1.0
    widths = [
        max(_MIN_COLUMN_PERCENT, p) - shortfall * (room / pool)
        for p, room in zip(raw, room_above_floor)
    ]
    return tuple(round(w, 1) for w in widths)


def table(
    headers: Sequence[str],
    rows: Sequence[Sequence[object]],
    align: str | Sequence[str] | None = None,
    mono: str | Sequence[bool] | None = None,
    nowrap: str | Sequence[bool] | None = None,
) -> Table | None:
    """Build a Table. `align` is e.g. "llrr" (left/right per column); `mono` is
    e.g. "mm.." (m = monospace, anything else = proportional); `nowrap` is e.g.
    "_nn_" (n = a column that only ever holds a short single-token value -- a
    percentage, a byte size, a state word. Its cell text never breaks mid-value,
    and its header renders rotated in the HTML output instead of horizontal, so
    a long header doesn't force the column wider than its data needs).
    Cell values may be plain strings, or (text, level) tuples to colour the cell.
    Returns None if there is nothing to render."""
    if not rows:
        return None
    n = len(headers)
    cells = tuple(tuple(_cell(c) for c in row) for row in rows)
    nowrap_t = _bool_tuple(nowrap, n, "n")
    return Table(
        headers=tuple(headers),
        rows=cells,
        align=_align_tuple(align, n),
        mono=_bool_tuple(mono, n, "m"),
        widths=_column_widths(headers, cells, nowrap_t),
        nowrap=nowrap_t,
    )


# Plain-text rendering, used only by the text/plain alternative in the e-mail.
def text_table(t: Table) -> str:
    """Render a Table as a fixed-width plain-text block (headers, a rule, then rows)."""
    cols = [[h for h in t.headers]] + [[c.text for c in row] for row in t.rows]
    widths = [max(len(str(x[i])) for x in cols) for i in range(len(t.headers))]

    def fmt(cells: Sequence[object]) -> str:
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
    """Strip HTML tags and unescape entities, for the plain-text e-mail alternative."""
    return html.unescape(_HTML_TAG.sub("", s)).strip()


# ----------------------------------------------------------------------------- data sources
def parse_csv(text: str) -> list[CsvRow]:
    """Parse an InfluxDB annotated-CSV response into row dicts; raises on a flux error table."""
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
    """Minimal client for InfluxDB's Flux HTTP query API (CSV response)."""

    def __init__(self, url: str) -> None:
        self.url = url.rstrip("/")

    def query(self, org: str, flux: str) -> list[CsvRow]:
        """Run a Flux query against `org` and return the parsed CSV rows.

        Reads the token from INFLUX_TOKEN_<ORG> in the environment.
        """
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
    """Minimal client for Loki's HTTP query API."""

    def __init__(self, url: str) -> None:
        self.url = url.rstrip("/")

    def _get(self, path: str, **params: object) -> dict:
        """GET `path` with `params` as the query string; returns the parsed JSON body."""
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

    def instant(self, query: str) -> list[tuple[dict[str, str], float]]:
        """Run an instant LogQL query and return (label set, value) pairs."""
        data = self._get("/loki/api/v1/query", query=query)
        return [(r["metric"], float(r["value"][1])) for r in data["data"]["result"]]

    def lines(self, selector: str, limit: int) -> list[tuple[int, str]]:
        """Newest `limit` lines of the last 24 h, newest first: [(timestamp_ns, line), ...]."""
        data = self._get(
            "/loki/api/v1/query_range", query=selector, limit=limit, since="24h"
        )
        out = [
            (int(ts), line) for s in data["data"]["result"] for ts, line in s["values"]
        ]
        return sorted(out, reverse=True)


def flux_values(
    *,
    bucket: str,
    measurement: str,
    fields: Sequence[str],
    tags: Sequence[str],
    agg: str = "last",
    since: str = "-10m",
    where: str = "",
) -> str:
    """Build a Flux query selecting `fields` of `measurement`, one row per tag-value combination.

    Keyword-only: with 7 parameters (two of which are same-typed lists), positional
    calls are too easy to get wrong.
    """
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


def pivot(
    rows: list[CsvRow], keys: Sequence[str]
) -> dict[tuple[str, ...], dict[str, str]]:
    """Group flux_values() rows by `keys` into {key_tuple: {field: value}}."""
    out = {}
    for r in rows:
        out.setdefault(tuple(r.get(k, "") for k in keys), {})[r["field"]] = r["value"]
    return out


TagT = TypeVar("TagT")


def metric(
    *,
    influx: Influx,
    org: str,
    measurement: str,
    tag_type: type[TagT],
    agg: str = "last",
    since: str = "-10m",
    where: str = "",
) -> list[tuple[TagT, float | None]]:
    """Query `measurement` and return (tags, numeric value) pairs, one per series.

    `tag_type` is a frozen dataclass (see the Tag classes below) whose field names
    are exactly the InfluxDB tags to select; each result row is unpacked into an
    instance of it, so callers get `sample.device` instead of `row["device"]` and
    a typo in a field name is a real AttributeError instead of a silent empty string.

    Keyword-only, same reasoning as flux_values() above.
    """
    tag_names = [f.name for f in fields(tag_type)]
    rows = influx.query(
        org,
        flux_values(
            bucket=org,
            measurement=measurement,
            # every InfluxDB line-protocol field name our exporters use for a plain value
            fields=["gauge", "counter", "value"],
            tags=tag_names,
            agg=agg,
            since=since,
            where=where,
        ),
    )
    return [
        (tag_type(**{t: r.get(t, "") for t in tag_names}), num(r["value"]))
        for r in rows
    ]


# ----- Influx series tags used with metric() (field names = the InfluxDB tags queried)
@dataclass(frozen=True)
class HostTag:
    host: str


@dataclass(frozen=True)
class NameTag:
    name: str


@dataclass(frozen=True)
class EntityTag:
    entity_id: str


@dataclass(frozen=True)
class ZpoolTag:
    zpool: str
    state: str


@dataclass(frozen=True)
class PoolTag:
    pool: str


@dataclass(frozen=True)
class MountpointTag:
    mountpoint: str


@dataclass(frozen=True)
class DeviceTag:
    device: str


@dataclass(frozen=True)
class DeviceModelTag:
    device: str
    model_name: str


@dataclass(frozen=True)
class DeviceAttributeTag:
    device: str
    attribute_name: str


@dataclass(frozen=True)
class DeviceAttributeValueTag:
    device: str
    attribute_name: str
    attribute_value_type: str


# ----------------------------------------------------------------------------- logs (errors first)
_NORMALIZE = [
    (re.compile(r"\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b", re.I), "<uuid>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b"), "<ip>"),
    (re.compile(r"\b0x[0-9a-f]+\b", re.I), "<hex>"),
    (re.compile(r"\b[0-9a-f]{12,}\b", re.I), "<hex>"),
    (re.compile(r"\d+"), "<n>"),
]


def normalize(line: str) -> str:
    """Replace UUIDs/IPs/hex/numbers with placeholders so similar log lines group together."""
    for rx, repl in _NORMALIZE:
        line = rx.sub(repl, line)
    return " ".join(line.split())


def summarize(lines: list[tuple[int, str]]) -> list[dict[str, object]]:
    """Group newest-first (ts, line) pairs by template: [{n, last, example}, ...], most frequent first."""
    groups = {}
    for ts, line in lines:
        g = groups.setdefault(normalize(line), {"n": 0, "last": ts, "example": line})
        g["n"] += 1
    return sorted(groups.values(), key=lambda g: -g["n"])


def _fmt_delta(cur: float, prev: float) -> tuple[str, int] | str:
    """Returns (text, level) for the 'vs previous' cell, or a bare "no data" dash."""
    if cur == 0 and prev == 0:
        return "—"  # nothing to compare, not a good/bad result -- stays uncoloured
    if not prev:
        return ("new", INFO)
    ratio = cur / prev
    # a >3x jump or <10x drop is only worth flagging once the volume is non-trivial,
    # otherwise e.g. 1 line -> 4 lines would trip the ratio check for no reason
    level = WARN if (ratio > 3 or ratio < 0.1) and max(cur, prev) >= 100 else OK
    return (f"{100 * (cur - prev) / prev:+.0f}%", level)


def log_errors_section(cfg: Config, loki: Loki, rep: Report) -> None:
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
            ["Source", "Count", "Last", "Message"],
            rows,
            align="lrrl",
            mono="m...",
            nowrap="_nn_",
        ),
        note,
    )


def log_volume_section(cfg: Config, loki: Loki, rep: Report) -> None:
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

    def short(name: str) -> str:
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
        ["Host", "Lines", "vs prev"],
        volume_rows,
        align="lrr",
        mono="m..",
        nowrap="_nn",
    )

    top = loki.instant(
        f"topk({2 * L['sources']}, sum by (host, {label}) (count_over_time({sel} [24h])))"
    )
    producer_rows = []
    for m, n in sorted(top, key=lambda kv: -kv[1])[: 2 * L["sources"]]:
        host, unit = m.get("host", "?"), m.get(label, "")
        producer_rows.append([f"{host}/{unit or 'kernel/other'}", f"{int(n):,}"])
    producer_tbl = table(
        ["Producer", "Lines"],
        producer_rows,
        align="lr",
        mono="m.",
        nowrap="_n",
    )

    rep.section("Log volume (last 24 h)", volume_tbl, producer_tbl)


# ----------------------------------------------------------------------------- Proxmox + PBS
def _proxmox_guests(
    *,
    influx: Influx,
    rep: Report,
    org: str,
    sec: str,
    thresholds: dict,
    reboot_s: float,
    expected_stopped: list[str],
) -> tuple[str, Table | None]:
    """LXC/VM inventory: flags guests that are down unexpectedly, recent restarts,
    and LXC memory/root-disk usage. Returns (summary HTML, fullest-disks table)."""
    T = thresholds
    guests = pivot(
        influx.query(
            org,
            flux_values(
                bucket=org,
                measurement="system",
                fields=["status", "uptime", "mem", "maxmem", "disk", "maxdisk"],
                tags=["host", "nodename", "object"],
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
            # a guest we deliberately keep stopped isn't a problem; anything else is
            if name in expected_stopped:
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
    disks.sort(reverse=True)  # highest usage % first
    summary = f"<p>{running} guests running, {stopped_ok} stopped as expected.</p>"
    disk_tbl = table(
        ["LXC disk", "Node", "Used", "%"],
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
        nowrap="_n_n",
    )
    return summary, disk_tbl


def _proxmox_stale_guests(
    *,
    influx: Influx,
    rep: Report,
    org: str,
    sec: str,
    thresholds: dict,
    known_removed: list[str],
) -> None:
    """Flag any host/guest whose `system.uptime` series hasn't updated recently.

    Queried separately from the guest inventory above: this looks at the raw
    per-series last-write time over 7 days, which also catches guests that have
    disappeared from Proxmox entirely (and so are absent from the inventory query).
    """
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
    now = time.time()
    for r in stale:
        age = now - int(r["t"]) / 1e9
        if age > thresholds["stale_minutes"] * 60 and r["host"] not in known_removed:
            rep.add(
                WARN,
                sec,
                f"{r['object']} {r['host']} has sent no metrics for {fmt_dur(age)}",
            )


def _proxmox_nodes(
    *,
    influx: Influx,
    rep: Report,
    org: str,
    sec: str,
    thresholds: dict,
    reboot_s: float,
) -> Table | None:
    """Per-node uptime, 24h average CPU, and current memory usage."""
    T = thresholds
    up = pivot(
        influx.query(
            org,
            flux_values(
                bucket=org,
                measurement="system",
                fields=["uptime"],
                tags=["host"],
                where=' and r.object == "nodes"',
            ),
        ),
        ["host"],
    )
    cpu = pivot(
        influx.query(
            org,
            flux_values(
                bucket=org,
                measurement="cpustat",
                fields=["cpu"],
                tags=["host"],
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
                bucket=org,
                measurement="memory",
                fields=["memused", "memtotal"],
                tags=["host"],
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
    return table(
        ["Node", "Uptime", "CPU 24h", "Memory"],
        node_rows,
        align="lrrr",
        mono="m...",
        nowrap="_nnn",
    )


def _proxmox_storages(
    *, influx: Influx, rep: Report, org: str, sec: str, thresholds: dict
) -> Table | None:
    """Proxmox storage usage, sorted by usage % (highest first)."""
    T = thresholds
    st = pivot(
        influx.query(
            org,
            flux_values(
                bucket=org,
                measurement="system",
                fields=["total", "used", "type", "shared"],
                tags=["host", "nodename"],
                where=' and r.object == "storages"',
            ),
        ),
        ["host", "nodename"],
    )
    # a shared storage is reported once per node that can see it; only count it once
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
    return table(
        ["Storage", "Node", "Type", "Used", "%"],
        [
            [name, node, typ, f"{fmt_bytes(u)} / {fmt_bytes(t)}", (f"{p:.0f}%", lvl_)]
            for p, name, node, typ, u, t, lvl_ in st_data
        ],
        align="lllrr",
        mono="mm...",
        nowrap="_nn_n",
    )


def _proxmox_pbs(
    *, influx: Influx, rep: Report, org: str, thresholds: dict
) -> Table | None:
    """PBS datastore usage, sorted by usage % (highest first)."""
    T = thresholds
    ds = pivot(
        influx.query(
            org,
            flux_values(
                bucket=org,
                measurement="blockstat",
                fields=["total", "used"],
                tags=["host", "datastore"],
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
    return table(
        ["PBS host", "Datastore", "Used", "%"],
        [
            [h, s, f"{fmt_bytes(u)} / {fmt_bytes(t)}", (f"{p:.0f}%", lvl_)]
            for p, h, s, u, t, lvl_ in ds_data
        ],
        align="llrr",
        mono="mm..",
        nowrap="n__n",
    )


def proxmox_section(cfg: Config, influx: Influx, rep: Report) -> None:
    """Proxmox guest/node/storage health and PBS datastore usage."""
    org, sec, T = "proxmox", "Proxmox", cfg["thresholds"]
    reboot_s = T["reboot_hours"] * 3600

    summary, disk_tbl = _proxmox_guests(
        influx=influx,
        rep=rep,
        org=org,
        sec=sec,
        thresholds=T,
        reboot_s=reboot_s,
        expected_stopped=cfg["expected_stopped"],
    )
    _proxmox_stale_guests(
        influx=influx,
        rep=rep,
        org=org,
        sec=sec,
        thresholds=T,
        known_removed=cfg["known_removed"],
    )
    node_tbl = _proxmox_nodes(
        influx=influx, rep=rep, org=org, sec=sec, thresholds=T, reboot_s=reboot_s
    )
    st_tbl = _proxmox_storages(influx=influx, rep=rep, org=org, sec=sec, thresholds=T)
    ds_tbl = _proxmox_pbs(influx=influx, rep=rep, org=org, thresholds=T)

    rep.section("Proxmox & PBS", summary, node_tbl, st_tbl, ds_tbl, disk_tbl)


# ----------------------------------------------------------------------------- NAS / offsite (ZFS, SMART, timers)
def _zfs_pools(
    *, influx: Influx, rep: Report, org: str, label: str, thresholds: dict
) -> Table | None:
    """ZFS pool state, usage % and fragmentation."""
    T = thresholds
    state = {
        tag.zpool: tag.state
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="node_zfs_zpool_state",
            tag_type=ZpoolTag,
        )
        if v and v > 0.5
    }
    size = {
        tag.pool: v
        for tag, v in metric(
            influx=influx, org=org, measurement="zfs_pool_size_bytes", tag_type=PoolTag
        )
    }
    alloc = {
        tag.pool: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="zfs_pool_allocated_bytes",
            tag_type=PoolTag,
        )
    }
    frag = {
        tag.pool: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="zfs_pool_fragmentation_ratio",
            tag_type=PoolTag,
        )
    }
    # zfs_pool_size_bytes/allocated aren't always exported (older zfs_exporter versions);
    # fall back to the generic node_exporter filesystem stats for the pool's root mount.
    zfs_where = ' and r.fstype == "zfs"'
    fs_size = {
        tag.mountpoint: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="node_filesystem_size_bytes",
            tag_type=MountpointTag,
            where=zfs_where,
        )
    }
    fs_avail = {
        tag.mountpoint: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="node_filesystem_avail_bytes",
            tag_type=MountpointTag,
            where=zfs_where,
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
        # zfs_exporter has reported fragmentation as both a 0-1 ratio and a 0-100
        # percentage across versions; normalise whichever we got to a percentage.
        fr_pct = (fr * 100 if fr <= 1 else fr) if fr is not None else None
        fr_level = lvl(fr_pct, T["zfs_frag_warn"]) if fr_pct is not None else OK
        pool_data.append(
            (
                p if p is not None else -1.0,  # sort unknown-usage pools last
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
                f"{fmt_bytes(used)} / {fmt_bytes(total)}" if total else "n/a",
                (f"{p:.0f}%", level) if p is not None else "n/a",
                (f"{fp:.0f}%", fl) if fp is not None else "n/a",
            ]
            for _sort, pool, s, used, total, p, level, fp, fl in pool_data
        ],
        align="llrrr",
        mono="m....",
        nowrap="_n_nn",
    )
    if not state:
        rep.add(WARN, label, "no ZFS pool state metrics found")
    return pool_tbl


def _other_filesystems(
    *, influx: Influx, rep: Report, org: str, label: str, thresholds: dict
) -> Table | None:
    """Non-ZFS filesystem usage, sorted by usage % (highest first)."""
    T = thresholds
    other_where = ' and (r.fstype == "ext4" or r.fstype == "xfs" or r.fstype == "btrfs" or r.fstype == "vfat")'
    o_size = {
        tag.mountpoint: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="node_filesystem_size_bytes",
            tag_type=MountpointTag,
            where=other_where,
        )
    }
    o_avail = {
        tag.mountpoint: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="node_filesystem_avail_bytes",
            tag_type=MountpointTag,
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
    return table(
        ["Filesystem", "Used", "%"],
        [
            [mount, f"{fmt_bytes(used)} / {fmt_bytes(total)}", (f"{p:.0f}%", lvl_)]
            for p, mount, used, total, lvl_ in fs_data
        ],
        align="lrr",
        mono="m..",
        nowrap="__n",
    )


def _smart_health(
    *, influx: Influx, rep: Report, org: str, label: str, thresholds: dict
) -> Table | None:
    """Per-disk SMART health: status, temperature, wear and any error attributes."""
    T = thresholds

    def by_dev(measurement: str, **kw: object) -> dict[str, float | None]:
        return {
            tag.device: v
            for tag, v in metric(
                influx=influx,
                org=org,
                measurement=measurement,
                tag_type=DeviceTag,
                **kw,
            )
        }

    model = {
        tag.device: tag.model_name
        for tag, _ in metric(
            influx=influx,
            org=org,
            measurement="smartctl_device",
            tag_type=DeviceModelTag,
        )
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
    now = time.time()
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
    for tag, v in metric(
        influx=influx,
        org=org,
        measurement="smartctl_device_attribute",
        tag_type=DeviceAttributeValueTag,
    ):
        if v is not None:
            attrs.setdefault(tag.device, {}).setdefault(tag.attribute_name, {})[
                tag.attribute_value_type
            ] = v
    bad_names = " or ".join(f'r.attribute_name == "{n}"' for n in BAD_ATTRS)
    # raw values of the "bad" attributes as of ~24h ago, to detect whether they grew
    old_raw = {
        (tag.device, tag.attribute_name): v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="smartctl_device_attribute",
            tag_type=DeviceAttributeTag,
            agg="first",
            since="-24h",
            where=f' and r.attribute_value_type == "raw" and ({bad_names})',
        )
    }

    if not (healthy or model):
        rep.add(WARN, label, "no SMART metrics found")

    def short(d: str) -> str:
        return f"{model.get(d, '?')} [{d if d.startswith('nvme') else d[-6:]}]"

    def flag(
        d: str, errs: list[tuple[int, str]], level: int, finding: str, cell: str
    ) -> None:
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

        temp_c = temp.get(d)
        tw, tc = (
            (T["nvme_temp_warn"], T["nvme_temp_crit"])
            if nvme
            else (T["temp_warn"], T["temp_crit"])
        )
        temp_level = lvl(temp_c, tw, tc) if temp_c is not None else OK
        if temp_level:
            rep.add(temp_level, label, f"{short(d)} is at {temp_c:.0f} C")

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
            check_cell = (fmt_dur_short(age), check_level)

        for name, abbr in BAD_ATTRS.items():
            raw = dattrs.get(name, {}).get("raw")
            if raw and raw > 0:
                # any non-zero value is at least a WARN; CRIT only once it's still climbing
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
            # smartctl_device_percentage_used isn't reported for SATA SSDs/HDDs; fall
            # back to whichever "remaining life" attribute the vendor does report.
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
                ("n/a" if ok is None else ("✓", OK) if ok >= 0.5 else ("✗", CRIT)),
                (f"{temp_c:.0f}C", temp_level) if temp_c is not None else "n/a",
                f"{poh[d] / 86400:.0f}d" if d in poh else "n/a",
                check_cell,
                (wear_text, w_level) if wear_text else "",
                fmt_bytes(written[d]) if d in written else "",
                (
                    (", ".join(x for _, x in errs), max(lv for lv, _ in errs))
                    if errs
                    else ("0", OK)
                ),
            ]
        )
    return table(
        [
            "Disk",
            "Health",
            "Temp",
            "Power-on",
            "Checked",
            "Wear",
            "Written",
            "Errors",
        ],
        smart_rows,
        align="llrrrrrl",
        mono="m.......",
        # Disk/Wear/Errors are free-form (long model names, "x% used, spare y%",
        # comma-joined error lists) and should still wrap; everything else is a
        # short single-token value that shouldn't ever break mid-value.
        nowrap="_nnnn_n_",
    )


def _timers(
    *,
    influx: Influx,
    rep: Report,
    org: str,
    label: str,
    timers: dict,
    up: float,
    now: float,
) -> Table | None:
    """Compare each configured systemd timer's last trigger time against its max age."""
    trig = {
        tag.name: v
        for tag, v in metric(
            influx=influx,
            org=org,
            measurement="node_systemd_timer_last_trigger_seconds",
            tag_type=NameTag,
        )
    }
    timer_rows = []
    for name, max_h in timers.items():
        if name not in trig:
            continue
        v = trig[name]
        if not v:
            # trigger time of 0 means it hasn't fired since the exporter started;
            # only worth a WARN once we're past the point it should have fired by
            if up < max_h * 3600:
                rep.add(
                    INFO, label, f"{name} has not fired since boot {fmt_dur(up)} ago"
                )
                timer_rows.append([name, "since boot"])
            else:
                rep.add(
                    WARN, label, f"{name} has not fired since boot {fmt_dur(up)} ago"
                )
                timer_rows.append([name, ("never", WARN)])
            continue
        age_h = (now - v) / 3600
        level = WARN if age_h > max_h else OK
        if level:
            rep.add(
                WARN,
                label,
                f"{name} last fired {fmt_dur(now - v)} ago (limit {max_h} h)",
            )
        timer_rows.append([name, (fmt_dur_short(now - v), level)])
    return table(["Timer", "Last run"], timer_rows, align="lr", mono="m.", nowrap="_n")


def _failed_units(*, influx: Influx, rep: Report, org: str, label: str) -> None:
    """Flag any systemd unit currently in the "failed" state."""
    for tag, v in metric(
        influx=influx,
        org=org,
        measurement="node_systemd_unit_state",
        tag_type=NameTag,
        where=' and r.state == "failed"',
    ):
        if v and v > 0.5:
            rep.add(CRIT, label, f"systemd unit {tag.name} is failed")


def host_section(
    cfg: Config, influx: Influx, rep: Report, org: str, label: str
) -> None:
    """ZFS pools, other filesystems, SMART health and systemd timers for one host."""
    T, now = cfg["thresholds"], time.time()

    boot = metric(
        influx=influx, org=org, measurement="node_boot_time_seconds", tag_type=HostTag
    )
    if not boot:
        rep.add(CRIT, label, "no metrics received in the last 10 minutes")
        rep.section(label, "<p>No metrics received.</p>")
        return
    load = metric(influx=influx, org=org, measurement="node_load15", tag_type=HostTag)
    up = now - boot[0][1]
    if up < T["reboot_hours"] * 3600:
        rep.add(WARN, label, f"rebooted {fmt_dur(up)} ago")
    intro = (
        f"<p>Uptime {fmt_dur(up)}"
        + (f", load15 {load[0][1]:.2f}" if load else "")
        + "</p>"
    )

    pool_tbl = _zfs_pools(influx=influx, rep=rep, org=org, label=label, thresholds=T)
    fs_tbl = _other_filesystems(
        influx=influx, rep=rep, org=org, label=label, thresholds=T
    )
    smart_tbl = _smart_health(
        influx=influx, rep=rep, org=org, label=label, thresholds=T
    )
    timer_tbl = _timers(
        influx=influx,
        rep=rep,
        org=org,
        label=label,
        timers=cfg["timers"],
        up=up,
        now=now,
    )
    _failed_units(influx=influx, rep=rep, org=org, label=label)

    rep.section(label, intro, pool_tbl, fs_tbl, smart_tbl, timer_tbl)


# ----------------------------------------------------------------------------- energy
def energy_section(cfg: Config, influx: Influx, rep: Report) -> None:
    """Home Assistant server-plug energy usage over the last 24 h."""
    e, org = cfg["energy"], "homeassistant"

    def one(measurement: str, entity: str, agg: str) -> float | None:
        rows = metric(
            influx=influx,
            org=org,
            measurement=measurement,
            tag_type=EntityTag,
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
def gatus_section(cfg: Config, loki: Loki, rep: Report) -> None:
    """Gatus endpoint check failure rates over the last 24 h, read from its Loki logs."""
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
            ["Endpoint", "Failed", "Checks", "Fail %"],
            rows,
            align="lrrr",
            mono="m...",
            nowrap="_nnn",
        ),
        msg,
    )


# ----------------------------------------------------------------------------- output
def load_template(path: str, filters: dict[str, Callable] | None = None) -> Template:
    """Load and compile a Jinja2 template from `path`, optionally registering custom filters."""
    try:
        with open(path) as f:
            source = f.read()
    except OSError as e:
        sys.exit(f"error: cannot read template {path}: {e}")
    env = Environment(autoescape=True)
    if filters:
        env.filters.update(filters)
    return env.from_string(source)


def render(
    cfg: Config,
    rep: Report,
    html_template: Template,
    text_template: Template,
    started: float,
) -> tuple[str, str, str, str]:
    """Render the HTML and text report bodies. Returns (status, subject, html, text)."""
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
        status_color=COLORS[STATUS_LEVEL[status]],
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


def save_report(cfg: Config, body_html: str, body_text: str) -> tuple[str, str, str]:
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


def write_index(cfg: Config, template: Template) -> None:
    """Regenerate index.html by scanning cfg["output_dir"] for report-*.html files."""
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
        color = COLORS[STATUS_LEVEL.get(status, INFO)]
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


def guarded(rep: Report, name: str, fn: Callable[..., None], *args: object) -> None:
    """Run `fn(*args)`, turning any exception into a WARN finding instead of aborting the run."""
    try:
        fn(*args)
    except Exception as e:  # keep the report going; the failure shows up as a warning
        rep.add(WARN, "report", f"{name} collector failed: {type(e).__name__}: {e}")


def discover(influx: Influx, org: str, prefix: str) -> None:
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


def main() -> None:
    """CLI entry point: parse args, collect sections, then render and save/send the report."""
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
    for host in cfg["hosts"]:
        guarded(
            rep, host["org"], host_section, cfg, influx, rep, host["org"], host["label"]
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
