# aranet4-bluetooth

Connect to an Aranet4 CO₂ monitor over Bluetooth Low Energy from a Mac — no
cloud, no vendor app.

The meter reports over a plain BLE GATT interface, and it also broadcasts every
reading in its advertisement. Two ways to get data:

| Mode | How | Cost |
|---|---|---|
| **Connected** | Connect, read characteristic `f0cd3001` (13 bytes) | Holds the BLE link; blocks the phone app briefly |
| **Passive** | Decode the BLE advertisement | No connection, no battery impact, works alongside the app |

Both are implemented and verified against a real Aranet4 (fw `v2.0.7` /
`v1.5.45`, serial `507340192088`).

## Menu bar app

There is also a single-file Swift menu bar app in [aranetbar/](aranetbar/), in the
style of the [`singlefilemenuapps`](../singlefilemenuapps) collection:

```bash
cd aranetbar
./aranetbar.swift          # run directly
./build.sh                 # or build AranetBar.app (gets its own Bluetooth permission)
open AranetBar.app
```

It reads the **advertisement only** — no GATT connection — so it runs all day
without touching the meter's battery and without fighting the Aranet phone app.
The menu bar shows a colour-coded dot plus the current CO₂, and the dropdown
breaks out every field. Scanning is duty-cycled (5 s on, 15 s off), which is
ample when the sensor only logs once every 5 minutes.

## Quick start

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

.venv/bin/python aranet.py scan     # confirm the meter is visible
.venv/bin/python aranet.py read     # connect once, print a reading
```

```
09:12:59  CO2  691 ppm  19.45 C   999.9 hPa  RH  38%  bat  80%  green   age  212s/300s
```

Other verbs:

```bash
aranet.py watch --poll 10          # poll while connected (Ctrl-C to stop)
aranet.py adv --window 10          # one-shot passive decode, no connection
aranet.py adv-watch                # continuous passive decode
aranet.py --json read              # machine-readable output
aranet.py read --fahrenheit        # temperature in degF
```

`--json` emits `{"co2_ppm": 691, "temperature_c": 19.45, ...}` — easy to pipe
into anything. With `--fahrenheit` it also includes `temperature_f`.

The meter itself always reports Celsius; `temperature_f` is derived
(`C × 9/5 + 32`), so there is no precision loss to worry about.

---

# Protocol reference

Everything below was determined by enumerating a real device, not from
documentation — Aranet does not publish this interface. Claims are tagged:

- ✅ **verified** — read directly off the device and cross-checked against
  physically plausible values (e.g. pressure ≈ 1000 hPa).
- ⚠️ **inferred** — consistent with observation but not proven.

All multi-byte fields are **little-endian**. BLE is 4.x, GATT, no MTU tricks
needed (largest characteristic is 244 bytes).

## 1. Discovery

| What | Value |
|---|---|
| Advertised name | `Aranet4 2EE58` (suffix is the unit's short ID) |
| Company ID | `0x0702` ✅ |
| Advertised service | `0xFCE0` |
| Manufacturer data length | 24 bytes, as delivered by CoreBluetooth |

To find the meter, scan for peripherals and accept one that either advertises a
name containing `aranet`, or whose manufacturer data carries company ID `0x0702`
and parses to plausible values. The company-ID check alone is a strong filter
and keeps working when macOS hands back a peripheral with no cached name.

On macOS, `CBPeripheral.identifier` is a **per-Mac UUID**, not the MAC address:

```
62352F09-C535-B415-7AFF-4D4DF2DAC7EF
```

That UUID differs on every Mac and can change if you unpair, so never hardcode
it. On Linux/BlueZ you do see the real hardware address
(`CC:43:4B:4A:42:F2`).

## 2. Advertising packet

The full current reading is in the advertisement, so you can read the sensor
without ever connecting — no bonding needed for this path.

CoreBluetooth hands you `CBAdvertisementDataManufacturerDataKey` as company ID
followed by the payload. Offsets below are **relative to the start of that
whole blob**, i.e. including the 2-byte company ID:

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 2 | Company ID | `0x0702`, little-endian → bytes `02 07` ✅ |
| 2 | 8 | Header | `21 07 00 02 00 12 0f 01` observed; not interpreted ⚠️ |
| 10 | 11 | **Reading** | CO₂ … interval — same struct as the GATT characteristic ✓ |
| 21 | 2 | Age | Seconds since that measurement ✅ |
| 23 | 1 | Trailer | `f1` / `f3` observed; not interpreted ⚠️ |

Worked example, captured from the device:

```
02 07 | 21 07 00 02 00 12 0f 01 | bc 02 a0 01 10 27 25 50 01 2c 01 | 9c 00 | f3
```

In words: 2-byte company ID, then an opaque 8-byte header, then the 11-byte
reading, then the 2-byte age, then a 1-byte trailer.

which decodes to:

| Field | Bytes | Maths | Value |
|---|---|---|---|
| CO₂ | `bc 02` | `0x02bc` | **700 ppm** |
| Temperature | `a0 01` | `0x01a0 / 20` | **20.80 °C** |
| Pressure | `10 27` | `0x2710 / 10` | **1000.0 hPa** |
| Humidity | `25` | — | **37 %** |
| Battery | `50` | — | **80 %** |
| Status | `01` | — | **green** |
| Interval | `2c 01` | `0x012c` | **300 s** |
| Age | `9c 00` | `0x009c` | **156 s** |

The meter advertises roughly once per second while idle. If the phone app holds
a connection, advertisements may pause — the readings are still there once the
link is released.

## 3. GATT services

### Device Information — `0000180A-0000-1000-8000-00805F9B34FB` ✅

| Characteristic | Value read |
|---|---|
| `2A29` Manufacturer Name | `SAF Tehnika` |
| `2A24` Model Number | `Aranet4` |
| `2A25` Serial Number | `507340192088` |
| `2A27` Hardware Revision | `18` |
| `2A26` Firmware Revision | `v2.0.7` |
| `2A28` Software Revision | `v1.5.45` |
| `2A23` PnP ID | `58 f9 d4 1f 76 a6 04 00` |

### Vendor service — `0000FCE0-0000-1000-8000-00805F9B34FB`

The service is `0xFCE0`. Every characteristic below shares the same 128-bit
suffix, `-95DA-4F4B-9AC8-AA55D312AF0C`:

| Characteristic | Props | Bytes | Meaning | |
|---|---|---|---|---|
| `f0cd3001` | read | 13 | **Current reading** — the one you want | ✅ |
| `f0cd1503` | read | 9 | Same reading, truncated after status | ✅ |
| `f0cd3002` | read | 12 | 9-byte reading + `ff ff 00` | ⚠️ |
| `f0cd2002` | read | 2 | Logging interval, seconds (300) | ✅ |
| `f0cd2004` | read | 2 | Seconds since last measurement (153) | ✅ |
| `f0cd1401` | read | 12 | Config; u16s `[24817, 129, 1000, 1400, 1000, 1400]` | ⚠️ |
| `f0cd1502` | read | 8 | `ff ff ff ff ff ff ff ff` — sentinel | ⚠️ |
| `f0cd2001` | read | 2 | `0x13b0` = 5040, constant across reads | ⚠️ |
| `f0cd2003` | read, notify | 244 | History buffer; all zero until requested | ⚠️ |
| `f0cd2005` | read | 244 | History page (see §6) | ⚠️ |
| `f0cd1402` | write | — | Command channel (history fetch) | ⚠️ |

`f0cd1401` decodes to CO₂ thresholds of **1000** and **1400** (each appearing
twice) — the same cut-offs the meter's LEDs and the `status` byte use. Treat
this as inferred: it is consistent with the data, but it was never verified by
changing the thresholds in the Aranet app.

> **Heads-up:** several blog posts and older libraries reference a `0xF371`
> service (`f371c4c1-…`). This firmware does **not** expose it. Enumerating the
> device is the only reliable way to find the real UUIDs.

## 4. Current reading — 13 bytes (canonical)

Characteristic `f0cd3001`:

| Off | Size | Field | Encoding | Range seen |
|---|---|---|---|---|
| 0 | u16 | CO₂ | ppm, raw | 400–5000+ |
| 2 | u16 | Temperature | **÷ 20** → °C | 425 → 21.25 °C |
| 4 | u16 | Pressure | **÷ 10** → hPa | 9999 → 999.9 hPa |
| 6 | u8 | Relative humidity | % | 0–100 |
| 7 | u8 | Battery | % | 0–100 |
| 8 | u8 | Status | enum, see below | 0–3 |
| 9 | u16 | Logging interval | seconds | 30–3600 |
| 11 | u16 | Age | seconds since measurement | 0–interval |

Example `b3 02 a9 01 0f 27 25 50 01 2c 01 99 00`:

```
CO₂   0x02b3 = 691      → 691 ppm
Temp  0x01a9 = 425      → 425/20  = 21.25 °C
Press 0x270f = 9999     → 9999/10 = 999.9 hPa
Hum   0x25   = 37       → 37 %
Bat   0x50   = 80       → 80 %
Stat  0x01   = 1        → green
Int   0x012c = 300      → 300 s
Age   0x0099 = 153      → 153 s
```

### Status byte

| Value | Meaning |
|---|---|
| 0 | error |
| 1 | green — good air |
| 2 | yellow — getting stuffy |
| 3 | red — ventilate |

The meter computes this from its own configured thresholds (see `f0cd1401`), so
prefer it over hardcoding your own CO₂ cut-offs.

### Interval and age

These two are what make the data honest:

- `interval` is how often the sensor logs — 300 s out of the box.
- `age` is how long ago the reported measurement was taken.

So a reading with `age: 290` and `interval: 300` is about to be replaced, while
`age: 5` is fresh. Anything much older than one interval means the meter is
stale, disconnected, or out of range. Both implementations flag this
(`Reading.is_stale` in Python, `AranetReading.isStale` in Swift) rather than
presenting an old number as live.

### The two shorter variants

- **`f0cd1503` (9 bytes)** — the 13-byte reading truncated after `status`; it
  drops `interval` and `age`. Byte-for-byte identical prefix. ✅
- **`f0cd3002` (12 bytes)** — the same 9 bytes followed by `ff ff 00`. The `ff`
  pair behaves like the "unset" sentinel in `f0cd1502`. ⚠️

## 5. Reading over GATT (connected path)

```
1. CBCentralManager.scanForPeripherals(withServices: nil)
2. match on name / company ID 0x0702
3. connect to the CBPeripheral
4. discoverServices([0xFCE0])
5. discoverCharacteristicsForService(0xFCE0)
6. readValueForCharacteristic(f0cd3001)   -> 13 bytes
7. parse per §4
8. disconnect (or leave connected to poll)
```

Only one central may hold the link at a time. While you are connected the
Aranet phone app cannot be, and vice versa.

**You do not actually need a connection to read the sensor** — the advertisement
already carries everything. A connection is only required for configuration and
for the history log.

## 6. History log — partially mapped ⚠️

Reading `f0cd2005` returns a 244-byte page that begins with a header and then a
run of 2-byte records. Header observed as:

```
03 | 2c 01 | b0 13 | 99 00 | 72 00 | ...
     interval   ?      age    ?
```

The records that follow decode plausibly as **pressure in 0.1 hPa**
(`f1 26` → 9969 → 996.9 hPa, and so on in a tight monotonic run), but the
record layout, page framing, and how to request older pages are **not**
reverse-engineered. Fetching the backlog requires writing commands to
`f0cd1402` (`f0cd2003` is the notify side of that exchange).

Nothing in this repo implements history. Live readings do not need it.

## 7. Test vectors

Use these to check any new parser. Both are real captures.

```
# GATT f0cd3001 (13 bytes)
b302a9010f272550012c019900
  co2=691  temp=21.25C  press=999.9hPa  hum=37  bat=80  status=green  interval=300  age=153

# advertisement, including company ID (24 bytes)
02072107000200120f01bc02a00110272550012c019c00f3
  co2=700  temp=20.80C  press=1000.0hPa  hum=37  bat=80  status=green  interval=300  age=156
```

The Python (`test_aranet.py`) and Swift (`--once`) implementations both parse
these identically.

---

## Getting connected on macOS

The device was **already paired** with this Mac, which is why nothing needs
pairing here. If you are starting from scratch:

1. **Pair it once** in System Settings → Bluetooth → *Aranet4*.
2. **Grant Bluetooth permission to your terminal.** macOS gates CoreBluetooth
   behind a TCC prompt on first use: System Settings → Privacy & Security →
   Bluetooth → enable your terminal (or the app running Python). Without this,
   `bleak` returns an empty device list with no error — the single most common
   "it just finds nothing" cause.
3. Verify outside Python: `system_profiler SPBluetoothDataType | grep -A2 Aranet`

Bluetooth Classic (`SPBluetoothDataType` above) is unrelated — BLE devices like
this one never appear there as a serial port. Do not look for an `rfcomm` or
`/dev/cu.*` device; there isn't one.

## Caveats

- **One connection at a time.** The Aranet phone app will fight you for the
  link. Use `adv` mode if you need both simultaneously.
- **The data only updates every `interval` seconds** (300 s here by default).
  Polling faster than that returns identical values — check `age_s` to tell how
  fresh a reading is.
- **Battery:** connected polling keeps the radio busy. Prefer `adv-watch` for
  always-on dashboards.
- **Parsing is validated, not verified.** Both parsers reject implausible values
  (CO₂ > 9999, temperature outside −40…80 °C) so a foreign packet cannot be
  mistaken for a reading. That is a sanity check, not a checksum.

## Files

- `aranet.py` — the Python client (parser + CLI)
- `aranetbar/aranetbar.swift` — the single-file Swift menu bar app
- `aranetbar/build.sh` — builds `AranetBar.app` with the Bluetooth usage strings
- `aranetbar/make_icon.py` — regenerates `AppIcon.icns`
- `scan.py`, `discover.py` — the exploration scripts used to map the device
- `test_aranet.py` — parser tests over captured payloads (`pytest -q`)
