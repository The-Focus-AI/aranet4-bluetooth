# AranetBar — macOS menu bar app

A single-file Swift menu bar utility that shows your Aranet4's CO₂, temperature,
humidity, pressure and battery — straight from the device's Bluetooth
advertisement.

<img src="icon-1024.png" width="128" alt="AranetBar icon">

## Quick start

```bash
./aranetbar.swift          # run directly
```

or build a proper `.app` bundle. This is the recommended way, because the bundle
gets its own Bluetooth permission entry instead of borrowing your terminal's:

```bash
./build.sh
open AranetBar.app
```

## Features

- 🌡️ **Live readings** — CO₂, temperature (°C and °F), humidity, pressure, battery
- 🔋 **Zero battery cost** — decodes the BLE advertisement and never opens a
  connection, so the Aranet phone app keeps working normally
- 🎨 **Colour-coded dot** in the menu bar, using the meter's own CO₂ thresholds
- 🔍 **Duty-cycled scanning** — 5 s of scanning every 20 s, which is plenty for a
  sensor that only logs every 5 minutes
- 🌡️ **°C / °F toggle**, remembered between launches
- 🕒 **Staleness aware** — dims when the last reading is older than expected
- 🧪 **Testable** — `--once` prints a reading and exits; `--dump-menu` renders the
  menu as text

## Usage

```bash
./aranetbar.swift               # menu bar app
./aranetbar.swift --verbose     # with logging
./aranetbar.swift --once        # print one reading and exit
./aranetbar.swift --dump-menu   # print the menu contents and exit
```

The menu bar shows a coloured dot plus the current CO₂ in ppm. Click for the full
readout:

```
TITLE: ●  680
  ARANET4 · Aranet4 12345
  CO₂    680 ppm
  Temperature    21.0 °C  ·  69.8 °F
  Humidity    37 %
  Pressure    999.8 hPa
  Battery    80 %
  Status    Green
  Signal    -52 dBm
  Measured    57s ago  ·  every 300s
  Show Fahrenheit
  Rescan Now
  Quit AranetBar
```

## Requirements

- macOS 13 or later, Xcode command line tools (`swiftc`)
- An Aranet4 CO₂ monitor, **paired** with your Mac (System Settings → Bluetooth)
- Bluetooth permission for the app — granted on first launch

## How it works

The meter broadcasts its full reading in the BLE advertisement under company ID
`0x0702`, so no GATT connection is required. After the 2-byte company ID there is
an 8-byte header, then the 11-byte reading, then the 2-byte age. In the 24-byte
blob CoreBluetooth delivers, the reading therefore starts at offset 10.

Full byte-level detail, including the GATT map and test vectors, is in
[../PROTOCOL.md](../PROTOCOL.md).

## Icon

`AppIcon.icns` is generated, not hand-drawn — a gauge using the meter's own
green/yellow/red CO₂ bands:

```bash
python3 make_icon.py        # needs Pillow; rewrites AppIcon.icns + icon-1024.png
```

Requires Pillow (`pip install pillow`) and macOS's `iconutil`.

## Files

- `aranetbar.swift` — the whole app
- `build.sh` — builds `AranetBar.app` (usage strings, icon, ad-hoc signing)
- `make_icon.py` — regenerates `AppIcon.icns` and `icon-1024.png`
- `AppIcon.icns`, `icon-1024.png` — the generated icon
