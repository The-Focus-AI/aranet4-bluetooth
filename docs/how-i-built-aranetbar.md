# The CO₂ meter was already broadcasting

### How I reverse-engineered an Aranet4's Bluetooth, pulled 17 days of history off it, and built a single-file macOS menu bar app for the graphs.

The X post version is: I built a macOS menu bar app that talks to my Aranet4, and the whole thing — protocol discovery included — cost eight cents.

The longer version is mostly about two things: a Bluetooth device that was already telling me everything, and an AppKit view that had to make 5,040 readings legible.

---

## The shortcut: the sensor was already talking

The Aranet4 is a CO₂ monitor. It has a display, a phone app, and a Bluetooth radio. What it also has is a BLE advertisement that contains the **entire current reading** — no connection, no pairing, no vendor app.

CoreBluetooth delivers the manufacturer data with the company ID already prefixed. The whole thing is 24 bytes:

```
02 07 | 21 07 00 02 00 12 0f 01 | bc 02 a0 01 10 27 25 50 01 2c 01 | 9c 00 | f3
company |       opaque header     |  reading (11 bytes)                 |  age   | trailer
```

The first two bytes are the Bluetooth SIG company ID `0x0702`, little-endian. Then comes an 8-byte header I never needed to understand, then the 11-byte reading, then the age of that reading in seconds.

The reading decodes like this:

```
bc 02 -> 0x02bc = 700       CO₂, ppm
a0 01 -> 0x01a0 / 20 = 20.8 temperature, °C
10 27 -> 0x2710 / 10 = 1000 pressure, hPa
25    -> 37                 humidity, %
50    -> 80                 battery, %
01    -> 1                  status: green
2c 01 -> 0x012c = 300       logging interval, seconds
```

The canonical GATT characteristic (`f0cd3001`) is the same 11 bytes plus the 2-byte age. So the advertisement parser and the connected parser can share almost everything: I take the 11-byte body, append the age bytes, and hand the resulting 13 bytes to the same decoder.

```swift
let company = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
guard company == 0x0702 else { return nil }

let body = Array(bytes[10..<21])            // 11-byte reading
let age  = UInt16(bytes[21]) | UInt16(bytes[22]) << 8
return decode13(body + [UInt8(age & 0xff), UInt8(age >> 8)])
```

This is the part I did not appreciate before starting: **you do not need a connection to read this sensor.** The advertisement is enough. No battery cost, no fighting the phone app for the BLE link, no pairing dance. The menu bar app scans for 5 seconds every 20 seconds. The meter only logs every 300 seconds by default, so that is already overkill.

There is one more honest detail in those bytes: `age` and `interval`. A reading with `age: 290` and `interval: 300` is about to be replaced. A reading with `age: 5` is fresh. The app shows a stale reading dimmed rather than pretending an old number is live.

---

## The menu bar app

The first version was deliberately small: one Swift file, one `NSStatusItem`, no dependencies beyond AppKit and CoreBluetooth.

The app runs as an accessory (`LSUIElement`), so there is no Dock icon. The status item title is an attributed string — a colored dot plus the CO₂ number in monospaced digits — and the menu breaks out temperature, humidity, pressure, battery, signal, status, and how long ago the measurement was taken. The dot uses the meter's own green/yellow/red status byte, not my own thresholds.

The live path never opens a connection. That is the whole trick. The radio wakes up, listens for an advertisement, and goes back to sleep. All the expensive work — the history download — happens only when you ask for it.

It builds with `swiftc`, signs ad-hoc, and ships as a universal binary in a zip. No package manager, no project file, no app framework.

---

## The real prize: 17 days of history

The menu bar is nice. The history log is the interesting part.

The Aranet4 keeps a ring buffer of **5,040 readings** — 17.5 days at the default 300-second interval. The buffer is not stored as a list of rows. It is stored **one parameter at a time**: all the CO₂ values, all the temperatures, all the humidities, all the pressures. You fetch each series separately and join them by index.

The request is four bytes written to `f0cd1402`:

```
61 | 04 | 01 00
cmd  param  first record (u16, little-endian, 1-based)
```

`04` is CO₂; the parameters are 1 temperature, 2 humidity, 3 pressure, 4 CO₂.

```swift
let command = Data([0x61, UInt8(param), UInt8(start & 0xff), UInt8(start >> 8)])
try await write(command, to: commandCharacteristic)

// One write, then read pages until start + count - 1 >= total.
let page = try await read(historyCharacteristic)
```

After that one write, each read of `f0cd2005` returns the next 244-byte page. No more writes are needed. The page starts with a 10-byte header:

```
param u8 | interval u16 | total u16 | age u16 | start u16 | count u8
```

Then come `count` values. CO₂, temperature and pressure are `u16`; humidity is `u8`. A full page carries 117 values for the u16 series, or 234 for humidity. The last page can be short.

Two protocol details saved me a lot of debugging:

- Before a new request is processed, `f0cd2005` can still return the last page it served. Ignore any page whose parameter does not match the request.
- The high bits are sentinels. Temperature sets `0x4000` when there is no measurement; pressure and CO₂ set `0x8000`; humidity is invalid above 100. If you ignore those, you will happily graph 32,768 ppm.

And then there is the timestamp problem. The meter stores no wall-clock time. It only knows how long ago the newest reading was taken and how often it logs. So:

```
newest = now - age
t(i)   = newest - (total - i) * interval
```

That is accurate to a few seconds as long as the meter was logging continuously at the same interval. Change the interval, power-cycle the meter, or wrap the ring buffer, and older timestamps drift. Treat the older end of the graph as approximate.

The download is a real GATT session: connect, discover the vendor service and Device Information service, read the record count and interval, request each series, read pages until the last index, join by index, disconnect. The live menu bar is still advertisement-only while this happens; the history refresh just borrows the link for 10–20 seconds.

The CoreBluetooth plumbing is less glamorous than the protocol. Reads and writes are callback-based, so I wrapped them in continuations with timeouts. One connection at a time. If the Aranet phone app is holding the link, the refresh fails gracefully and the cached snapshot stays on screen. The per-series `age` values jitter by a second or two, so the app uses the median anchor across the four series.

---

## Drawing 17 days

The history window is a custom `NSView`, not a charting library.

Four panels share one time axis: CO₂, temperature, humidity, pressure. Each panel gets its own nicely rounded y-scale, a line, a soft fill, a last-point dot, and a header with the min–max, average and latest value for the visible range. The CO₂ panel adds dashed 800 and 1000 ppm reference lines.

Under the hood it is a flipped `NSView`: each sample's x position is a linear interpolation of its timestamp, each panel rounds its y-axis to a 1 / 2 / 2.5 / 5 / 10 step, and the hover lookup is a binary search over the sample timestamps.

The data has gaps. A missing measurement is `nil`, not zero, so the line breaks instead of diving to the bottom of the chart. That one decision makes the graph trustworthy.

Hovering shows a crosshair and a readout for the nearest sample. The date formatter switches from `HH:mm` to `MMM d` depending on the span. The whole thing is drawn with CoreGraphics and dynamic `NSColor`s, so it works in light and dark mode.

![AranetBar history window showing 17.5 days of CO₂, temperature, humidity and pressure](aranetbar-history-all.png)

*Sample data from a real Aranet4; serial redacted.*

The interaction is where the front end earns its keep:

- **24 h / 7 days / All** presets.
- **Scroll up/down** to zoom around the cursor, not the center.
- **Scroll left/right** to pan through time.
- **Double-click** to reset to the selected preset.
- **Hover** for a crosshair and a sample readout.
- **Refresh** to pull a new snapshot; **Export CSV** to save it.

![The same history window zoomed to 24 hours](aranetbar-history-24h.png)

The zoom math is small but fussy. Keep the time under the pointer anchored, divide the visible span by a factor, clamp to the available history, and clamp the factor per scroll event so one accelerated wheel event cannot jump from 17 days to a few hours. Horizontal gestures pan by a fraction of the visible span, and diagonal gestures follow the dominant axis.

```swift
let targetSpan = currentSpan / factor
let anchor = layout.date(atX: point.x)
let fraction = anchor.timeIntervalSince(layout.start) / currentSpan
let start = anchor.addingTimeInterval(-fraction * targetSpan)
```

5,040 points per panel is nothing for CoreGraphics. The hard part was deciding what the time axis should do.

There is also a boring-but-important piece underneath: snapshots are cached as JSON under `~/Library/Application Support/AranetBar/`, one file per meter. The window opens instantly and still has something to show when that meter is out of range. The network-shaped problem was actually a cache-shaped problem.

The multi-meter part is a cache-keying problem too. Aranets do not put a serial number in their advertisement, so the app uses the CoreBluetooth peripheral identifier as the key; the serial only arrives after a GATT connection. The menu bar follows one active meter, switching only when the old one has been quiet for 45 seconds or a new one is 8 dBm stronger for 10 seconds. Without that hysteresis, two meters at similar range make the reading flip back and forth. History is loaded and saved under the active identifier, so a snapshot downloaded at home can never appear under the office meter.

The same identifier keys the optional display name. “Office” and “Living Room” are just local aliases in `UserDefaults`; the meter's advertised Bluetooth name is untouched. That keeps the naming feature small and makes the alias travel with the meter's history without a second database.

---

## The macOS details that bit me

Two things about shipping a menu bar app on a modern Mac:

**A menu bar app with no Dock icon can be running and completely invisible.** The app is an accessory, so a Finder double-click while it is already running did nothing: no Dock icon, no window, no visible change. Worse, when the menu bar is full, macOS can park the status item under the camera housing. I now handle the Finder reopen event to open the History window, and at launch I check the screen's auxiliary top areas to see whether the status item is hidden under the notch. If it is, the app opens History instead of disappearing.

**Gatekeeper still cares.** The app is ad-hoc signed, not notarized. Building it locally is fine; sending it to someone else means right-click → Open the first time, or `xattr -dr com.apple.quarantine AranetBar.app`. If I were shipping this to strangers, I would pay for a Developer ID and notarize it. For a personal tool, ad-hoc is fine.

There are smaller lessons too: the app gets its own Bluetooth permission entry as a bundle, the Aranet phone app and this app cannot hold the GATT link at the same time, and a menu bar app's "no visible window" state is a design decision, not an accident.

---

## Testing hardware without a test rig

I did not want to click around the UI every time I changed a parser, so the app grew a few headless modes:

```
./aranetbar.swift --once          # print one advertisement reading and exit
./aranetbar.swift --dump-menu     # render the menu as text
./aranetbar.swift --history       # download the log, print a summary
./aranetbar.swift --render-history chart.png
```

The history renderer was especially useful. It draws the real window offscreen to a PNG, which meant I could check the chart layout, the axis labels, and the dark-mode colors without opening a window. The screenshots in this article came out of that path.

The protocol itself is pinned by real captures, not mocks: a 13-byte GATT reading, a 24-byte advertisement, and a 244-byte history page. The Python client and the Swift app parse the same bytes, and there are tests for the sentinel values, page lengths, timestamp reconstruction, CSV output and the advertisement offset. When both implementations agree with each other and with the live characteristic, the protocol is probably right.

---

## What I would keep

**Passive first.** If the device already broadcasts the data, do not open a connection for the live path. It is better for battery, better for coexistence with the vendor app, and dramatically simpler.

**Cache the expensive path.** The history download takes 10–20 seconds and needs the radio link. The graph should open instantly from the cache and refresh behind the scenes.

**Treat time as part of the protocol.** The meter has no clock. Reconstructing timestamps from `age` and `interval` is the difference between a useful history and a bag of numbers.

**The front end is the product.** The Bluetooth work gets the bytes; the chart, the hover readout and the scroll behavior are what make the data usable.

**Notarize before strangers.** Ad-hoc signing is fine for a personal tool. The moment someone else downloads it, spend the money.

The repo is at [The-Focus-AI/aranet4-bluetooth](https://github.com/The-Focus-AI/aranet4-bluetooth). The protocol notes are in [PROTOCOL.md](https://github.com/The-Focus-AI/aranet4-bluetooth/blob/main/PROTOCOL.md), and the latest build is on the [releases page](https://github.com/The-Focus-AI/aranet4-bluetooth/releases/latest).

The meter was already broadcasting. I just had to listen, then make it legible.
