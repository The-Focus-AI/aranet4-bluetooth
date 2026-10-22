# AranetBar

A macOS menu bar utility that shows your Aranet4's CO₂, temperature, humidity,
pressure and battery — straight from the device's Bluetooth advertisement.

<img src="icon-1024.png" width="128" alt="AranetBar icon">

## Quick Start

```bash
chmod +x aranetbar.swift
./aranetbar.swift
```

Or build a proper `.app` bundle. This is the recommended way, because the bundle
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
readout.

## Requirements

- macOS 13 or later
- An Aranet4 CO₂ monitor, **paired** with your Mac (System Settings → Bluetooth)
- Bluetooth permission for the app — granted on first launch

## How it works

The meter broadcasts its full reading in the BLE advertisement under company ID
`0x0702`, so no GATT connection is required. The 11-byte reading starts 8 bytes
into the payload, followed by the measurement age. See the
[protocol notes](../README.md#the-gatt-map) for the byte layout.

---

🔧 **[View Source Code](aranetbar.swift)**
