# Protocol reference

How the Aranet4 exposes its measurements over Bluetooth Low Energy.

Everything here was determined by enumerating a real Aranet4 (firmware
`v2.0.7`, software `v1.5.45`), not from documentation — Aranet does not publish
this interface. Claims are tagged:

- ✅ **verified** — read directly off the device and cross-checked against
  physically plausible values (e.g. pressure ≈ 1000 hPa).
- ⚠️ **inferred** — consistent with observation but not proven.

All multi-byte fields are **little-endian**. BLE 4.x, GATT, no MTU tricks needed
(the largest characteristic is 244 bytes).

Both implementations in this repo ([Python](python/) and [Swift](swift/)) parse
this identically; see the [test vectors](#7-test-vectors).

---

## 1. Discovery

| What | Value |
|---|---|
| Advertised name | `Aranet4 XXXXX` — suffix is the unit's short ID |
| Company ID | `0x0702` ✅ |
| Advertised service | `0xFCE0` |
| Manufacturer data length | 24 bytes, as delivered by CoreBluetooth |

To find the meter, scan for peripherals and accept one that either advertises a
name containing `aranet`, or whose manufacturer data carries company ID `0x0702`
and parses to plausible values. The company-ID check alone is a strong filter
and keeps working when macOS hands back a peripheral with no cached name.

On macOS, `CBPeripheral.identifier` is a **per-Mac UUID**, not the MAC address:

```
A1B2C3D4-E5F6-7890-ABCD-EF0123456789   (example)
```

That UUID differs on every Mac and can change if you unpair, so never hardcode
it. On Linux/BlueZ you do see the real hardware address (`AA:BB:CC:DD:EE:FF`).

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
| 10 | 11 | **Reading** | CO₂ … interval — same struct as the GATT characteristic ✅ |
| 21 | 2 | Age | Seconds since that measurement ✅ |
| 23 | 1 | Trailer | `f1` / `f3` observed; not interpreted ⚠️ |

Worked example, captured from the device:

```
02 07 | 21 07 00 02 00 12 0f 01 | bc 02 a0 01 10 27 25 50 01 2c 01 | 9c 00 | f3
```

In words: 2-byte company ID, then an opaque 8-byte header, then the 11-byte
reading, then the 2-byte age, then a 1-byte trailer.

The reading decodes to:

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

| Characteristic | Value |
|---|---|
| `2A29` Manufacturer Name | `SAF Tehnika` |
| `2A24` Model Number | `Aranet4` |
| `2A25` Serial Number | 12 ASCII digits |
| `2A27` Hardware Revision | `18` |
| `2A26` Firmware Revision | `v2.0.7` |
| `2A28` Software Revision | `v1.5.45` |
| `2A23` PnP ID | 8 bytes |

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
| `f0cd2001` | read | 2 | **Total stored readings** (5040 = 17.5 days at 300 s) | ✅ |
| `f0cd2003` | read, notify | 244 | Legacy history notifications (ignored by v2.0.7) | ✅ |
| `f0cd2005` | read | 244 | **History page** — 10-byte header + values (see §6) | ✅ |
| `f0cd1402` | write | — | Command channel: history requests, interval/range config | ✅ |

`f0cd1401` decodes to CO₂ thresholds of **1000** and **1400** (each appearing
twice) — the same cut-offs the meter's LEDs and the `status` byte use. Treat
this as inferred: it is consistent with the data, but it was never verified by
changing the thresholds in the Aranet app.

> **Firmware gotcha:** the service UUID is not stable across firmware. This unit
> (v1.2.0+) exposes `0000fce0-…`; pre-v1.2.0 firmware exposes
> `f0cd1400-95da-4f4b-9ac8-aa55d312af0c` instead. Try both, and enumerate the
> device rather than hardcoding either.

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

## 6. History log — verified ✅

The meter keeps a ring buffer of stored measurements, newest at the highest
index. `f0cd2001` reports its size: **5,040 records**, i.e. 17.5 days at the
default 300 s interval. Once full, the oldest records are overwritten.

The buffer is stored **one parameter at a time**, not as interleaved records.
Each series is fetched separately and then joined by index. There are no
absolute timestamps on the device — see §6.4.

### 6.1 Request a series

Write 4 bytes to the command characteristic `f0cd1402`:

| Offset | Size | Field |
|---|---|---|
| 0 | u8 | Command `0x61` |
| 1 | u8 | Parameter, see table |
| 2 | u16 | First record index (1-based) |

Example: `61 04 01 00` = CO₂, from record 1.

| Value | Parameter | Stored as |
|---|---|---|
| 1 | temperature | u16, ÷ 20 → °C |
| 2 | humidity | u8, % |
| 3 | pressure | u16, ÷ 10 → hPa |
| 4 | CO₂ | u16, ppm |

Then read `f0cd2005` repeatedly. Each successful read returns the next page —
no further write is needed. A page is always 244 bytes.

### 6.2 Page layout

Header, 10 bytes, little endian:

| Offset | Size | Field |
|---|---|---|
| 0 | u8 | Parameter (echoes the request) |
| 1 | u16 | Logging interval, seconds |
| 3 | u16 | Total stored records |
| 5 | u16 | Age of the newest record, seconds |
| 7 | u16 | Index of the first value in this page (1-based) |
| 9 | u8 | Number of values in this page |

Then `count` values starting at offset 10: u16 each, except humidity, which is
u8. A full page therefore carries 117 values (u16) or 234 values (humidity).
The final page may be short; ignore the unused tail. Stop when
`start + count - 1 >= total`.

### 6.3 Value sentinels

| Parameter | Invalid when | Result |
|---|---|---|
| temperature | bit 14 set (`0x4000`) | no measurement |
| pressure | bit 15 set (`0x8000`) | no measurement |
| CO₂ | bit 15 set (`0x8000`) | no measurement |
| humidity | value > 100 | no measurement |

The high bits are set while the sensor cannot measure (for example during CO₂
calibration), so a decoder must not present `0x8000` as 32768 ppm. Humidity is
a single byte, so the usual `value >> 8` test cannot fire; `0xff` (255) is
treated as invalid.

### 6.4 Timestamps (reconstructed)

The device stores no wall-clock time per record. It reports:

- `age` — seconds since the newest record was measured;
- `interval` — seconds between records.

With `total` records and index `i` (1 = oldest):

```
newest = now - age
t(i)   = newest - (total - i) * interval
```

This is only as good as the assumption that the meter logged continuously at
the current interval. Changing the interval, power-cycling, or a full buffer
shifts older entries. Treat timestamps as accurate to a few seconds.

### 6.5 Worked example

Request CO₂ from index 1 (`61 04 01 00`), then read `f0cd2005`:

```
04 | 2c 01 | b0 13 | 82 00 | 01 00 | 75 | 25 02 0c 02 28 02 12 02 ...
    300 s    5040    130 s    start 1  117  549   524   552   530
```

- parameter 4 (CO₂), interval 300 s, 5,040 records stored, newest 130 s ago
- the page starts at record 1 and carries 117 values
- values 549, 524, 552, 530 … ppm
- the last record of the series matched the live characteristic (713 ppm) at
  capture time, confirming the index and timestamp mapping ✅

Before a request is processed, `f0cd2005` returns the last page it served (often
a pressure page, parameter 3). Ignore pages whose parameter does not match the
request.

### 6.6 Legacy path (not used by this firmware)

Older firmware used `f0cd2003` notifications with a different command:
`82 <param> 00 00 <start u16> <end u16>`. On firmware v2.0.7 / software
v1.5.45 this command is ignored — subscribing yields a single stale page and
nothing else. New firmware serves history through the `0x61` protocol above.

### 6.7 Implementation

[`python/aranet.py history`](python/aranet.py) implements §6.1–6.4, downloads all
four series in about 20 s, joins them by index, and writes CSV or JSON. See the
[Python README](python/README.md#history).

AranetBar's **History…** window implements the same protocol directly with
CoreBluetooth, caches the last snapshot in
`~/Library/Application Support/AranetBar/history.json`, and draws it as four
stacked charts. See the [Swift README](swift/README.md#history-window).

## 7. Test vectors

Use these to check any new parser. All are real captures.

```
# GATT f0cd3001 (13 bytes)
b302a9010f272550012c019900
  co2=691  temp=21.25C  press=999.9hPa  hum=37  bat=80  status=green  interval=300  age=153

# advertisement, including company ID (24 bytes)
02072107000200120f01bc02a00110272550012c019c00f3
  co2=700  temp=20.80C  press=1000.0hPa  hum=37  bat=80  status=green  interval=300  age=156

# history page f0cd2005, prefix of the first CO2 page (full page = 117 values)
04 2c 01 b0 13 82 00 01 00 75 25 02 0c 02 28 02 12 02
  param=4  interval=300  total=5040  age=130  start=1  count=117
  values: 549 524 552 530 552 ... (page continues)
```
