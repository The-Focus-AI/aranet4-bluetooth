#!/usr/bin/env python3
"""Talk to an Aranet4 CO2 monitor over Bluetooth Low Energy.

Tested on macOS 26 with Python 3.14 + bleak (CoreBluetooth backend), against an
Aranet4 firmware v2.0.7 / 1.5.45.

Three ways to get data:

  1. Connected  - connect and read characteristic f0cd3001 (13 bytes, full
                  reading incl. log interval + staleness).
  2. Passive    - decode the BLE advertisement. No connection at all, so it
                  costs no battery and does not block the Aranet phone app.
  3. History    - download the on-board ring buffer (5,040 readings) to CSV
                  or JSON, with reconstructed timestamps.

Usage:
    python aranet.py scan            # list nearby Aranet devices
    python aranet.py read            # connect once, print current readings
    python aranet.py watch           # poll while connected
    python aranet.py adv             # one-shot passive advertisement decode
    python aranet.py adv-watch       # continuous passive decode
    python aranet.py history         # download the stored log to CSV
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import json
import struct
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta
from math import ceil
from pathlib import Path
from typing import Any, Iterable, TextIO

from bleak import BleakClient, BleakScanner

# --------------------------------------------------------------------------
# GATT identifiers, discovered by enumerating the device (see README).
# The service is the vendor-specific 0xFCE0 base. Note: many blog posts and
# older libraries mention a 0xF371 service; this firmware does not expose it.
# --------------------------------------------------------------------------
SERVICE_UUID = "0000fce0-0000-1000-8000-00805f9b34fb"
CHAR_CURRENT = "f0cd3001-95da-4f4b-9ac8-aa55d312af0c"       # 13B full reading
CHAR_CURRENT_SHORT = "f0cd1503-95da-4f4b-9ac8-aa55d312af0c"  # 9B, no interval/age
CHAR_INTERVAL = "f0cd2002-95da-4f4b-9ac8-aa55d312af0c"      # 2B log interval
CHAR_AGE = "f0cd2004-95da-4f4b-9ac8-aa55d312af0c"          # 2B seconds since update
CHAR_LOG = "f0cd2003-95da-4f4b-9ac8-aa55d312af0c"          # 244B legacy history notify
CHAR_TOTAL = "f0cd2001-95da-4f4b-9ac8-aa55d312af0c"        # 2B stored record count
CHAR_HISTORY = "f0cd2005-95da-4f4b-9ac8-aa55d312af0c"      # 244B history page (v2)
CHAR_CMD = "f0cd1402-95da-4f4b-9ac8-aa55d312af0c"          # write: history/config cmds

CHAR_SERIAL = "00002a25-0000-1000-8000-00805f9b34fb"
CHAR_FIRMWARE = "00002a26-0000-1000-8000-00805f9b34fb"

# History is stored as one series per parameter, fetched and joined by index.
HISTORY_TEMPERATURE = 1
HISTORY_HUMIDITY = 2
HISTORY_PRESSURE = 3
HISTORY_CO2 = 4
HISTORY_PARAM_NAMES = {
    HISTORY_TEMPERATURE: "temperature",
    HISTORY_HUMIDITY: "humidity",
    HISTORY_PRESSURE: "pressure",
    HISTORY_CO2: "co2",
}
HISTORY_PARAMS = (HISTORY_CO2, HISTORY_PRESSURE, HISTORY_TEMPERATURE, HISTORY_HUMIDITY)

ARANET_MFR_ID = 0x0702
# In the advertisement payload the 11-byte reading starts at byte 8, followed
# by the 2-byte age at byte 19 (payload is 22 bytes total).
ADV_READING_OFFSET = 8
ADV_READING_LEN = 11
ADV_AGE_OFFSET = 19

STATUS_NAMES = {0: "error", 1: "green", 2: "yellow", 3: "red"}

# Display preference, set once by --fahrenheit. Kept module-level so the flag
# does not have to be threaded through every command function.
DISPLAY_FAHRENHEIT = False

ADDRESS_CACHE = Path(__file__).with_name(".aranet-address")


# --------------------------------------------------------------------------
# Data model
# --------------------------------------------------------------------------
@dataclass
class Reading:
    co2_ppm: int
    temperature_c: float
    pressure_hpa: float
    humidity_pct: int
    battery_pct: int
    status: str
    interval_s: int = 0
    age_s: int = 0

    @property
    def is_stale(self) -> bool:
        """True if the last measurement is older than one logging interval."""
        return self.interval_s > 0 and self.age_s > self.interval_s

    @property
    def temperature_f(self) -> float:
        return self.temperature_c * 9 / 5 + 32


@dataclass(frozen=True)
class HistoryPageHeader:
    """Header of one f0cd2005 page (10 bytes, little endian)."""

    param: int
    interval_s: int
    total_readings: int
    age_s: int
    start: int  # 1-based index of the first value in this page
    count: int


@dataclass
class HistoryRecord:
    """One stored measurement, with its reconstructed timestamp."""

    timestamp: datetime
    co2_ppm: int | None = None
    temperature_c: float | None = None
    humidity_pct: int | None = None
    pressure_hpa: float | None = None


@dataclass
class History:
    """A downloaded slice of the meter's ring buffer."""

    name: str
    serial: str
    firmware: str
    interval_s: int
    total_records: int
    start_index: int
    fetched_at: datetime
    records: list[HistoryRecord] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------
def parse_reading(data: bytes | Iterable[int]) -> Reading:
    """Decode the Aranet4 13-byte current-reading characteristic.

    Layout (little endian):
        0-1  CO2 ppm
        2-3  temperature, 1/20 degC
        4-5  pressure, 1/10 hPa
        6    relative humidity %
        7    battery %
        8    status (0 error, 1 green, 2 yellow, 3 red)
        9-10 logging interval, seconds
        11-12 seconds since last measurement
    """
    buf = bytes(data)
    if len(buf) < 13:
        raise ValueError(f"reading needs 13 bytes, got {len(buf)}")

    co2, temp_raw, press_raw = struct.unpack_from("<HHH", buf, 0)
    interval, age = struct.unpack_from("<HH", buf, 9)

    return Reading(
        co2_ppm=co2,
        temperature_c=temp_raw / 20.0,
        pressure_hpa=press_raw / 10.0,
        humidity_pct=buf[6],
        battery_pct=buf[7],
        status=STATUS_NAMES.get(buf[8], f"unknown({buf[8]})"),
        interval_s=interval,
        age_s=age,
    )


def parse_advertisement(manufacturer_data: dict[int, bytes]) -> Reading | None:
    """Decode a Reading out of the Aranet4 advertisement, without connecting."""
    payload = manufacturer_data.get(ARANET_MFR_ID)
    if payload is None or len(payload) < ADV_AGE_OFFSET + 2:
        return None

    reading = payload[ADV_READING_OFFSET : ADV_READING_OFFSET + ADV_READING_LEN]
    age = struct.unpack_from("<H", payload, ADV_AGE_OFFSET)[0]
    # Rebuild the canonical 13-byte form so both paths share one parser.
    return parse_reading(reading + struct.pack("<H", age))


def parse_history_header(data: bytes | Iterable[int]) -> HistoryPageHeader:
    """Decode the 10-byte header at the start of an f0cd2005 page.

    Layout: param u8, interval u16, total readings u16, age u16,
    start u16 (1-based), count u8.
    """
    buf = bytes(data)
    if len(buf) < 10:
        raise ValueError(f"history page needs at least 10 bytes, got {len(buf)}")
    return HistoryPageHeader(*struct.unpack_from("<BHHHHB", buf, 0))


def parse_history_page(
    data: bytes | Iterable[int],
) -> tuple[HistoryPageHeader, list[int]]:
    """Decode one page into its header and raw values.

    Values are u16 for CO2/temperature/pressure and u8 for humidity. The page
    is 244 bytes; a full page carries 117 u16 values or 234 u8 values.
    """
    buf = bytes(data)
    header = parse_history_header(buf)
    if header.param not in HISTORY_PARAM_NAMES:
        raise ValueError(f"unknown history parameter {header.param}")
    if header.count == 0:
        return header, []

    size = 1 if header.param == HISTORY_HUMIDITY else 2
    available = (len(buf) - 10) // size
    if available < header.count:
        raise ValueError(
            f"history page declares {header.count} values but only {available} fit"
        )
    fmt = f"<{header.count}{'B' if size == 1 else 'H'}"
    return header, list(struct.unpack_from(fmt, buf, 10))


def decode_history_value(param: int, raw: int) -> int | float | None:
    """Apply the device's scaling and sentinel bits to a raw history value.

    The top bits flag measurements the sensor could not take (e.g. while CO2
    calibration is running); those come back as None rather than a magic number.
    """
    if param == HISTORY_TEMPERATURE:
        if raw & 0x4000:
            return None
        return raw / 20.0
    if param == HISTORY_PRESSURE:
        if raw & 0x8000:
            return None
        return raw / 10.0
    if param == HISTORY_CO2:
        if raw & 0x8000:
            return None
        return raw
    if param == HISTORY_HUMIDITY:
        return raw if raw <= 100 else None
    raise ValueError(f"unknown history parameter {param}")


def history_start_index(
    total: int, *, last: int | None = None, days: float | None = None, interval_s: int
) -> int:
    """Translate --last / --days into a 1-based start index."""
    if last is not None:
        count = last
    elif days is not None:
        if interval_s <= 0:
            raise ValueError("--days needs the logging interval, but the device reported 0")
        count = ceil(days * 86400 / interval_s)
    else:
        return 1
    return max(1, total - count + 1)


def build_history_records(
    series: dict[int, dict[int, int | float | None]],
    *,
    total: int,
    interval_s: int,
    start: int,
    last_measured_at: datetime,
) -> list[HistoryRecord]:
    """Join the per-parameter series and reconstruct each record's timestamp.

    The device stores no absolute time: the last record was taken `age` seconds
    ago and earlier records sit `interval` seconds apart. This assumes the meter
    logged continuously at the current interval.
    """
    records: list[HistoryRecord] = []
    for index in range(start, total + 1):
        row = {param: values.get(index) for param, values in series.items()}
        if all(value is None for value in row.values()):
            continue
        records.append(
            HistoryRecord(
                timestamp=last_measured_at
                - timedelta(seconds=(total - index) * interval_s),
                co2_ppm=row.get(HISTORY_CO2),
                temperature_c=row.get(HISTORY_TEMPERATURE),
                humidity_pct=row.get(HISTORY_HUMIDITY),
                pressure_hpa=row.get(HISTORY_PRESSURE),
            )
        )
    return records


# --------------------------------------------------------------------------
# Device discovery
# --------------------------------------------------------------------------
def _is_aranet(device: Any, adv: Any) -> bool:
    name = f"{device.name or ''} {adv.local_name or ''}".lower()
    return "aranet" in name


async def find_device(address: str | None = None, timeout: float = 20.0):
    """Locate the Aranet4 by name (macOS hides real MAC addresses)."""
    if address:
        device = await BleakScanner.find_device_by_address(address, timeout=timeout)
        if device:
            return device
        print(f"Could not find {address} while scanning.", file=sys.stderr)

    # Advertising data is needed for name matching on macOS.
    discovered = await BleakScanner.discover(timeout=timeout, return_adv=True)
    for dev, adv in discovered.values():
        if _is_aranet(dev, adv):
            return dev
    return None


async def resolve_device(address: str | None, timeout: float) -> Any:
    device = await find_device(address, timeout)
    if device is None and address is None and ADDRESS_CACHE.exists():
        cached = ADDRESS_CACHE.read_text().strip()
        if cached:
            device = await find_device(cached, timeout)
    if device is None:
        raise SystemExit(
            "No Aranet device found.\n"
            "  - Is it powered on and within a few metres?\n"
            "  - Is it paired in System Settings > Bluetooth?\n"
            "  - Bluetooth permission for your terminal: System Settings > "
            "Privacy & Security > Bluetooth."
        )
    ADDRESS_CACHE.write_text(device.address)
    return device


# --------------------------------------------------------------------------
# Connected reads
# --------------------------------------------------------------------------
async def read_once(device: Any) -> Reading:
    async with BleakClient(device, timeout=30.0) as client:
        data = await client.read_gatt_char(CHAR_CURRENT)
        return parse_reading(data)


async def watch_connected(device: Any, poll_s: float, count: int | None, as_json: bool) -> None:
    seen = 0
    async with BleakClient(device, timeout=30.0) as client:
        print(f"Connected to {device.name}. Ctrl-C to stop.\n", flush=True)
        while count is None or seen < count:
            try:
                data = await client.read_gatt_char(CHAR_CURRENT)
                reading = parse_reading(data)
            except Exception as exc:  # transient drop / device took the link
                print(f"read failed: {exc}", file=sys.stderr)
                await asyncio.sleep(poll_s)
                continue
            print(format_reading(reading, as_json), flush=True)
            seen += 1
            if count is not None and seen >= count:
                break
            await asyncio.sleep(poll_s)


# --------------------------------------------------------------------------
# History download
# --------------------------------------------------------------------------
async def _read_u16(client: BleakClient, characteristic: str) -> int:
    data = await client.read_gatt_char(characteristic)
    if len(data) < 2:
        raise ValueError(f"{characteristic} returned {len(data)} bytes, expected 2")
    return struct.unpack_from("<H", data)[0]


async def _read_text(client: BleakClient, characteristic: str) -> str:
    try:
        data = await client.read_gatt_char(characteristic)
    except Exception:  # optional metadata must not break the download
        return ""
    return data.decode("utf-8", "replace").strip("\x00 ")


async def _fetch_history_param(
    client: BleakClient,
    param: int,
    start: int,
    total: int,
    timeout: float,
) -> tuple[dict[int, int | float | None], datetime, int, int]:
    """Fetch one parameter's series, starting at the 1-based index `start`.

    Write `61 <param> <start u16>` then read f0cd2005: each read returns the
    next page, so one write downloads the rest of the series.
    """
    await client.write_gatt_char(
        CHAR_CMD, struct.pack("<BBH", 0x61, param, start), response=True
    )

    values: dict[int, int | float | None] = {}
    last_measured_at: datetime | None = None
    page_total = total
    page_interval = 0
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        packet = await client.read_gatt_char(CHAR_HISTORY)
        try:
            header, raw_values = parse_history_page(packet)
        except ValueError:
            await asyncio.sleep(0.05)
            continue

        if header.param != param or header.count == 0:
            # The characteristic still holds the previously served page until
            # the fresh request takes effect; ignore it and read again.
            await asyncio.sleep(0.1)
            continue

        if last_measured_at is None:
            now = datetime.now().astimezone().replace(microsecond=0)
            last_measured_at = now - timedelta(seconds=header.age_s)
            page_total = header.total_readings or total
            page_interval = header.interval_s

        for offset, raw in enumerate(raw_values):
            index = header.start + offset
            if start <= index <= page_total:
                values[index] = decode_history_value(param, raw)

        if header.start + header.count - 1 >= page_total:
            return values, last_measured_at, page_total, page_interval

    raise TimeoutError(
        f"no complete page after {timeout:.0f}s for "
        f"{HISTORY_PARAM_NAMES.get(param, param)}"
    )


async def fetch_history(
    device: Any,
    *,
    last: int | None = None,
    days: float | None = None,
    timeout: float = 60.0,
) -> History:
    """Download the stored log, optionally limited to the most recent records."""
    fetched_at = datetime.now().astimezone().replace(microsecond=0)

    async with BleakClient(device, timeout=30.0) as client:
        name = device.name or ""
        serial = await _read_text(client, CHAR_SERIAL)
        firmware = await _read_text(client, CHAR_FIRMWARE)
        total = await _read_u16(client, CHAR_TOTAL)
        interval = await _read_u16(client, CHAR_INTERVAL)

        if total == 0:
            return History(name, serial, firmware, interval, 0, 1, fetched_at)

        start = history_start_index(total, last=last, days=days, interval_s=interval)
        series: dict[int, dict[int, int | float | None]] = {}
        warnings: list[str] = []
        anchors: list[datetime] = []

        for param in HISTORY_PARAMS:
            try:
                values, last_measured, page_total, page_interval = (
                    await _fetch_history_param(client, param, start, total, timeout)
                )
            except (TimeoutError, ValueError) as exc:
                warnings.append(f"{HISTORY_PARAM_NAMES[param]}: {exc}")
                series[param] = {}
                continue

            series[param] = values
            anchors.append(last_measured)
            # The page header is the authority if f0cd2002 disagrees.
            interval = page_interval or interval
            total = max(total, page_total)

        if not anchors:
            raise TimeoutError("the device returned no history pages")

        anchors.sort()
        last_measured_at = anchors[len(anchors) // 2]
        records = build_history_records(
            series,
            total=total,
            interval_s=interval,
            start=start,
            last_measured_at=last_measured_at,
        )

    return History(
        name=name,
        serial=serial,
        firmware=firmware,
        interval_s=interval,
        total_records=total,
        start_index=start,
        fetched_at=fetched_at,
        records=records,
        warnings=warnings,
    )


# --------------------------------------------------------------------------
# Passive (advertisement only)
# --------------------------------------------------------------------------
async def adv_once(timeout: float, as_json: bool) -> None:
    reading = await _adv_capture(timeout)
    if reading is None:
        raise SystemExit("No Aranet advertisement seen.")
    print(format_reading(reading, as_json))


async def watch_adv(timeout: float, as_json: bool) -> None:
    print("Listening passively. Ctrl-C to stop.\n", flush=True)
    last: Reading | None = None
    # Aranet advertises roughly once per second while idle.
    while True:
        reading = await _adv_capture(timeout)
        if reading is not None and reading != last:
            print(format_reading(reading, as_json), flush=True)
            last = reading


async def _adv_capture(timeout: float) -> Reading | None:
    found: list[Reading] = []

    def on_detect(device, adv) -> None:
        if _is_aranet(device, adv):
            reading = parse_advertisement(adv.manufacturer_data)
            if reading is not None:
                found.append(reading)

    scanner = BleakScanner(detection_callback=on_detect)
    await scanner.start()
    try:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and not found:
            await asyncio.sleep(0.1)
    finally:
        await scanner.stop()
    return found[0] if found else None


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
def format_reading(r: Reading, as_json: bool) -> str:
    if as_json:
        out = asdict(r)
        if DISPLAY_FAHRENHEIT:
            out["temperature_f"] = round(r.temperature_f, 2)
        return json.dumps(out)
    stale = "  (stale)" if r.is_stale else ""
    temp = f"{r.temperature_f:5.1f} F" if DISPLAY_FAHRENHEIT else f"{r.temperature_c:5.2f} C"
    return (
        f"{time.strftime('%H:%M:%S')}  "
        f"CO2 {r.co2_ppm:4d} ppm  "
        f"{temp}  "
        f"{r.pressure_hpa:6.1f} hPa  "
        f"RH {r.humidity_pct:3d}%  "
        f"bat {r.battery_pct:3d}%  "
        f"{r.status:<6s}  age {r.age_s:4d}s/{r.interval_s}s{stale}"
    )


HISTORY_CSV_COLUMNS = (
    "timestamp",
    "co2_ppm",
    "temperature_c",
    "humidity_pct",
    "pressure_hpa",
    "epoch_s",
)


def history_row(record: HistoryRecord) -> dict[str, Any]:
    return {
        "timestamp": record.timestamp.isoformat(timespec="seconds"),
        "co2_ppm": record.co2_ppm,
        "temperature_c": record.temperature_c,
        "humidity_pct": record.humidity_pct,
        "pressure_hpa": record.pressure_hpa,
        "epoch_s": int(record.timestamp.timestamp()),
    }


def write_history_csv(history: History, fh: TextIO) -> None:
    writer = csv.DictWriter(fh, fieldnames=HISTORY_CSV_COLUMNS, lineterminator="\n")
    writer.writeheader()
    for record in history.records:
        writer.writerow(history_row(record))


def history_document(history: History) -> dict[str, Any]:
    return {
        "device": {
            "name": history.name,
            "serial": history.serial,
            "firmware": history.firmware,
        },
        "interval_s": history.interval_s,
        "total_records": history.total_records,
        "start_index": history.start_index,
        "fetched_at": history.fetched_at.isoformat(timespec="seconds"),
        "records": [history_row(record) for record in history.records],
    }


def write_history_json(history: History, fh: TextIO) -> None:
    json.dump(history_document(history), fh, indent=2)
    fh.write("\n")


def _stats(values: Iterable[int | float | None]) -> tuple[float, float, float] | None:
    present = [v for v in values if v is not None]
    if not present:
        return None
    return min(present), max(present), sum(present) / len(present)


def format_history_summary(history: History, destination: str) -> str:
    count = len(history.records)
    first = history.records[0].timestamp
    last = history.records[-1].timestamp
    noun = "record" if count == 1 else "records"
    lines = [
        f"{history.name or 'Aranet4'}  ·  SN {history.serial or '?'}  "
        f"·  fw {history.firmware or '?'}",
        f"{count} {noun} at {history.interval_s} s  "
        f"{first.strftime('%Y-%m-%d %H:%M')} → {last.strftime('%Y-%m-%d %H:%M %Z')}",
    ]

    def span(stats: tuple[float, float, float], unit: str, digits: int) -> str:
        low, high = stats[0], stats[1]
        if low == high:
            return f"{low:.{digits}f}{unit}"
        return f"{low:.{digits}f}–{high:.{digits}f}{unit}"

    parts = []
    co2 = _stats(r.co2_ppm for r in history.records)
    temp = _stats(r.temperature_c for r in history.records)
    humidity = _stats(r.humidity_pct for r in history.records)
    pressure = _stats(r.pressure_hpa for r in history.records)
    if co2:
        label = f"CO2 {span(co2, ' ppm', 0)}"
        if co2[0] != co2[1]:
            label += f" (avg {co2[2]:.0f})"
        parts.append(label)
    if temp:
        parts.append(span(temp, " °C", 2))
    if humidity:
        parts.append(f"RH {span(humidity, '%', 0)}")
    if pressure:
        parts.append(span(pressure, " hPa", 1))
    if parts:
        lines.append("  ·  ".join(parts))

    lines.append(f"Wrote {count} {noun} to {destination}")
    return "\n".join(lines)


async def cmd_scan(timeout: float) -> None:
    print(f"Scanning {timeout:.0f}s ...", flush=True)
    discovered = await BleakScanner.discover(timeout=timeout, return_adv=True)
    hits = [(d, a) for d, a in discovered.values() if _is_aranet(d, a)]
    if not hits:
        print("No Aranet devices found.")
        return
    for device, adv in hits:
        reading = parse_advertisement(adv.manufacturer_data)
        print(f"{device.name}  [{device.address}]  rssi={adv.rssi}")
        if reading:
            print(f"    {format_reading(reading, False)}")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def _default_history_path(fmt: str) -> str:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"aranet-history-{stamp}.{fmt}"


async def history_command(device: Any, args: argparse.Namespace) -> None:
    try:
        history = await fetch_history(device, last=args.last, days=args.days)
    except (TimeoutError, ValueError) as exc:
        raise SystemExit(str(exc))

    for warning in history.warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if not history.records:
        raise SystemExit("No stored measurements returned.")

    fmt = args.format
    if fmt is None:
        if args.json:
            fmt = "json"
        elif args.out and args.out != "-":
            suffix = Path(args.out).suffix.lower().lstrip(".")
            fmt = suffix if suffix in ("csv", "json") else "csv"
        else:
            fmt = "csv"

    out = args.out
    if out is None:
        out = "-" if args.json else _default_history_path(fmt)

    if out == "-":
        if fmt == "json":
            write_history_json(history, sys.stdout)
        else:
            write_history_csv(history, sys.stdout)
        print(format_history_summary(history, "stdout"), file=sys.stderr)
        return

    with open(out, "w", encoding="utf-8", newline="") as fh:
        if fmt == "json":
            write_history_json(history, fh)
        else:
            write_history_csv(history, fh)
    print(format_history_summary(history, out))


def _add_common(p: argparse.ArgumentParser, *, suppress: bool) -> None:
    """Register --address/--timeout/--json so they work before or after the verb."""
    d = argparse.SUPPRESS if suppress else None
    p.add_argument(
        "--address",
        default=d,
        help="CoreBluetooth UUID / MAC (skips name search)",
    )
    p.add_argument("--timeout", type=float, default=d, help="scan timeout")
    p.add_argument("--json", action="store_true", default=d, help="emit JSON")
    p.add_argument(
        "--fahrenheit", action="store_true", default=d, help="show temperature in degF"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Aranet4 BLE client")
    _add_common(parser, suppress=False)
    parser.set_defaults(address=None, timeout=20.0, json=False, fahrenheit=False)
    sub = parser.add_subparsers(dest="command", required=True)

    def verb(name: str, help_text: str) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help_text)
        _add_common(p, suppress=True)  # SUPPRESS = don't clobber the global default
        return p

    verb("scan", "list nearby Aranet devices")
    verb("read", "connect once and print the current reading")

    p_one = verb("adv", "decode the advertisement without connecting")
    p_one.add_argument("--window", type=float, default=10.0, help="scan window seconds")

    p_watch = verb("watch", "poll the device while connected")
    p_watch.add_argument("--poll", type=float, default=10.0, help="seconds between polls")
    p_watch.add_argument("--count", type=int, default=None, help="stop after N samples")

    p_adv = verb("adv-watch", "listen to advertisements continuously")
    p_adv.add_argument("--window", type=float, default=5.0, help="scan window seconds")

    p_hist = verb("history", "download stored measurements (CSV by default)")
    limit = p_hist.add_mutually_exclusive_group()
    limit.add_argument("--last", type=int, metavar="N", help="only the newest N records")
    limit.add_argument(
        "--days", type=float, metavar="N", help="only records from the last N days"
    )
    p_hist.add_argument(
        "--out", metavar="PATH", help="output file (default: aranet-history-<time>.csv; - for stdout)"
    )
    p_hist.add_argument(
        "--format", choices=("csv", "json"), help="output format (default: from --out)"
    )

    args = parser.parse_args()
    if args.command == "history":
        if args.last is not None and args.last < 1:
            parser.error("--last must be at least 1")
        if args.days is not None and args.days <= 0:
            parser.error("--days must be greater than 0")

    global DISPLAY_FAHRENHEIT
    DISPLAY_FAHRENHEIT = args.fahrenheit

    if args.command == "scan":
        asyncio.run(cmd_scan(args.timeout))
        return

    if args.command == "adv":
        asyncio.run(adv_once(args.window, args.json))
        return

    if args.command == "adv-watch":
        asyncio.run(watch_adv(args.window, args.json))
        return

    async def connected() -> None:
        device = await resolve_device(args.address, args.timeout)
        if args.command == "read":
            reading = await read_once(device)
            print(format_reading(reading, args.json))
        elif args.command == "history":
            await history_command(device, args)
        else:
            await watch_connected(device, args.poll, args.count, args.json)

    try:
        asyncio.run(connected())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
