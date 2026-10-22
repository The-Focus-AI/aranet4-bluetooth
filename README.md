# aranet4-bluetooth

Read an Aranet4 CO₂ monitor over Bluetooth Low Energy from a Mac — no cloud, no
vendor app, no account.

Two complete, independent implementations. Either one stands on its own:

| | Implementation | Best for |
|---|---|---|
| 🖥️ | [**AranetBar**](swift/) — single-file Swift menu bar app | CO₂ at a glance, always running |
| 🐍 | [**aranet.py**](python/) — scriptable Python CLI + library | Automation, JSON, dashboards |

Both decode the same data and produce identical values. The wire format is
documented in [PROTOCOL.md](PROTOCOL.md).

## A neat property of this device

The Aranet4 **broadcasts every measurement in its BLE advertisement**. So you can
read it without ever opening a connection — which means no battery cost and no
fighting the Aranet phone app for the BLE link. That is how the menu bar app
works. The Python client can do either: passive advertisement decoding, or a
real GATT connection when you want the full 13-byte characteristic.

---

## 🖥️ Swift — AranetBar

<img src="swift/icon-1024.png" width="96" alt="AranetBar icon">

A menu bar utility in the spirit of the *singlefilemenuapps* collection: one
file, one purpose, nothing beyond system frameworks.

```bash
cd swift
./aranetbar.swift          # run it directly
```

or build a proper bundle, which gets its own Bluetooth permission entry:

```bash
cd swift
./build.sh
open AranetBar.app
```

The menu bar shows a colour-coded dot plus the current CO₂; the dropdown breaks
out temperature (°C and °F), humidity, pressure, battery, signal and staleness.
Reads the advertisement only, scans on a 5 s / 20 s duty cycle, and never opens a
connection.

→ [Full details](swift/README.md)

## 🐍 Python — aranet.py

A CLI and importable parser. Connects over GATT *or* decodes the advertisement,
and emits either a readable line or JSON.

```bash
python3 -m venv .venv
.venv/bin/pip install -r python/requirements.txt

.venv/bin/python python/aranet.py scan     # is the meter visible?
.venv/bin/python python/aranet.py read     # one connected reading
.venv/bin/python python/aranet.py adv      # passive, no connection
```

```
09:12:59  CO2  691 ppm  19.45 C   999.9 hPa  RH  38%  bat  80%  green   age  212s/300s
```

```bash
.venv/bin/python python/aranet.py watch --poll 10   # poll while connected
.venv/bin/python python/aranet.py adv-watch         # passive stream
.venv/bin/python python/aranet.py --json read       # JSON output
.venv/bin/python python/aranet.py read --fahrenheit
```

→ [Full details](python/README.md)

---

## Repo layout

```
python/       Python CLI, parser and tests
swift/        AranetBar menu bar app, build script and icon generator
PROTOCOL.md   The BLE wire format, reverse-engineered and tagged verified/inferred
```

## Requirements

- **Swift app:** macOS 13+, Xcode command line tools (`swiftc`). First launch
  asks for Bluetooth permission — allow it.
- **Python client:** Python 3.10+, `bleak`. Your terminal needs Bluetooth
  permission (System Settings → Privacy & Security → Bluetooth); without it the
  scan silently returns nothing.
- **The meter:** paired once in System Settings → Bluetooth.

## Caveats

- **One connection at a time.** The Aranet phone app will fight you for the link;
  use the passive (`adv`) path if you need both at once.
- **Readings only change every `interval`** (300 s by default), so polling faster
  is pointless. Both implementations report `age` so you can tell how fresh the
  data is instead of being misled.
- The history log is **not** implemented — see [PROTOCOL.md §6](PROTOCOL.md#6-history-log--partially-mapped-).
