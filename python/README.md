# aranet.py — Aranet4 Python client

A CLI and importable parser for the Aranet4 CO₂ monitor, built on
[bleak](https://github.com/hbldh/bleak). Works on macOS (CoreBluetooth) and
should work on Linux/Windows too.

Two ways to read the meter:

| Mode | Command | Cost |
|---|---|---|
| **Connected** | `read`, `watch` — a real GATT connection | Holds the BLE link |
| **Passive** | `adv`, `adv-watch` — decode the advertisement | No connection, no battery cost |

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
```

```
09:12:59  CO2  691 ppm  19.45 C   999.9 hPa  RH  38%  bat  80%  green   age  212s/300s
```

Common options (accepted before or after the verb):

| Flag | Meaning |
|---|---|
| `--json` | one JSON object per line |
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
```

## Tests

```bash
.venv/bin/python -m pytest python/ -q      # 12 tests over real captured payloads
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
- `test_aranet.py` — parser tests
- `scan.py`, `discover.py` — the exploration scripts used to map the device
  (handy if you need to re-enumerate services for new firmware)
