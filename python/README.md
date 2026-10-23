# aranet.py — Aranet4 Python client

A CLI and importable parser for the Aranet4 CO₂ monitor, built on
[bleak](https://github.com/hbldh/bleak). Works on macOS (CoreBluetooth) and
should work on Linux/Windows too.

Three ways to read the meter:

| Mode | Command | Cost |
|---|---|---|
| **Connected** | `read`, `watch` — a real GATT connection | Holds the BLE link |
| **Passive** | `adv`, `adv-watch` — decode the advertisement | No connection, no battery cost |
| **History** | `history` — download the on-board ring buffer | Holds the link for ~20 s |

The wire format is documented in [../PROTOCOL.md](../PROTOCOL.md).

## Install

```bash
# from the repo root
python3 -m venv .venv
.venv/bin/pip install -r python/requirements.txt
```

## Commands

```bash
.venv/bin/python python/aranet.py scan            # list nearby Aranet devices
.venv/bin/python python/aranet.py read            # connect once, print a reading
.venv/bin/python python/aranet.py watch           # poll while connected
.venv/bin/python python/aranet.py adv             # one-shot passive decode
.venv/bin/python python/aranet.py adv-watch       # continuous passive decode
.venv/bin/python python/aranet.py history         # download stored data to CSV
```

```
09:12:59  CO2  691 ppm  19.45 C   999.9 hPa  RH  38%  bat  80%  green   age  212s/300s
```

Common options (accepted before or after the verb):

| Flag | Meaning |
|---|---|
| `--json` | JSON (one object per line for `read`; one document for `history`) |
| `--fahrenheit` | display temperature in °F (adds `temperature_f` to JSON) |
| `--timeout N` | scan timeout in seconds (default 20) |
| `--address ID` | skip the name search and use a known identifier |
| `--poll N` / `--count N` | `watch` only: seconds between polls, sample limit |

```bash
.venv/bin/python python/aranet.py --json read
# {"co2_ppm": 691, "temperature_c": 21.25, "pressure_hpa": 999.9, ...}

.venv/bin/python python/aranet.py watch --poll 30 --count 5
.venv/bin/python python/aranet.py adv-watch --window 5
```

## History

The meter keeps a ring buffer of 5,040 readings — 17.5 days at the default
300 s interval. `history` downloads all four parameters, joins them by index,
and writes CSV (or JSON) with reconstructed timestamps:

```bash
.venv/bin/python python/aranet.py history
# Aranet4 12345  ·  SN 123456789012  ·  fw v2.0.7
# 5040 records at 300 s  2026-10-04 21:54 → 2026-10-22 09:49 EDT
# CO2 471–890 ppm (avg 563)  ·  12.95–23.85 °C  ·  RH 36–62%  ·  ...
# Wrote 5040 rows to aranet-history-20261022-0953.csv
```

| Option | Meaning |
|---|---|
| `--last N` | only the newest N records |
| `--days N` | only records from the last N days |
| `--out PATH` | output file; `-` writes to stdout (default `aranet-history-<time>.csv`) |
| `--format csv\|json` | explicit format; otherwise inferred from `--out`, or CSV |
| `--json` | shorthand for JSON on stdout |

```bash
.venv/bin/python python/aranet.py history --last 288 --out aranet-history-day.csv
.venv/bin/python python/aranet.py history --days 7 --format json --out aranet-history-week.json
.venv/bin/python python/aranet.py history --json | jq '.records[-1]'
```

CSV columns: `timestamp` (local ISO 8601 with offset), `co2_ppm`,
`temperature_c`, `humidity_pct`, `pressure_hpa`, `epoch_s`.

**Timestamps are reconstructed, not stored.** The device only knows how long
ago the newest reading was taken and the logging interval, so older entries are
counted backwards. Expect a few seconds of slop; if the interval was changed or
the meter was powered off, the oldest entries shift accordingly.

## Library use

The parser has no I/O and no dependencies, so it is easy to reuse:

```python
from aranet import parse_reading, parse_advertisement

reading = parse_reading(bytes.fromhex("b302a9010f272550012c019900"))
print(reading.co2_ppm, reading.temperature_c, reading.temperature_f)

# or from a BLE library's manufacturer data, keyed by company ID 0x0702
reading = parse_advertisement(adv.manufacturer_data)
if reading.is_stale:
    print("last measurement is older than the logging interval")

# history pages decode without I/O too
from aranet import parse_history_page

header, raw_values = parse_history_page(page)
print(header.param, header.interval_s, header.start, raw_values[:4])
```

## Tests

```bash
.venv/bin/python -m pytest python/ -q      # 33 tests over real captured payloads
```

## macOS notes

- **The address is a UUID, not a MAC.** macOS hides hardware addresses from
  CoreBluetooth; `CBPeripheral.identifier` is per-Mac and can change on unpair.
  This tool finds the meter by name and caches the identifier in
  `.aranet-address` (gitignored) to skip the ~10 s scan next time.
- **Bluetooth permission is a silent failure.** If your terminal lacks it,
  `bleak` returns an empty device list and no error.
- **One connection at a time** — the Aranet phone app competes for the link.

## Files

- `aranet.py` — the client and parser
- `test_aranet.py` — live-reading parser tests
- `test_history.py` — history parser tests (real captured pages)
- `scan.py`, `discover.py` — the exploration scripts used to map the device
  (handy if you need to re-enumerate services for new firmware)
