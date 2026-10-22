#!/usr/bin/env python3
"""Talk to an Aranet4 CO2 monitor over Bluetooth Low Energy.

Tested on macOS 26 with Python 3.14 + bleak (CoreBluetooth backend), against an
Aranet4 firmware v2.0.7 / 1.5.45.

Two ways to get data:

  1. Connected  - connect and read characteristic f0cd3001 (13 bytes, full
                  reading incl. log interval + staleness).
  2. Passive    - decode the BLE advertisement. No connection at all, so it
                  costs no battery and does not block the Aranet phone app.

Usage:
    python aranet.py scan            # list nearby Aranet devices
    python aranet.py read            # connect once, print current readings
    python aranet.py watch           # poll while connected
    python aranet.py adv             # one-shot passive advertisement decode
    python aranet.py adv --watch     # continuous passive decode
"""

from __future__ import annotations

import argparse
import asyncio
import json
import struct
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

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
CHAR_LOG = "f0cd2003-95da-4f4b-9ac8-aa55d312af0c"          # 244B history buffer
CHAR_CMD = "f0cd1402-95da-4f4b-9ac8-aa55d312af0c"          # write: log fetch cmds

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
def _add_common(p: argparse.ArgumentParser, *, suppress: bool) -> None:
    """Register --address/--timeout/--json so they work before or after the verb."""
    d = argparse.SUPPRESS if suppress else None
    p.add_argument(
        "--address",
        default=d,
        help="CoreBluetooth UUID / MAC (skips name search)",
    )
    p.add_argument("--timeout", type=float, default=d, help="scan timeout")
    p.add_argument("--json", action="store_true", default=d, help="emit JSON lines")
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

    args = parser.parse_args()

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
