#!/usr/bin/env swift
//
// AranetBar
// Aranet4 CO2 monitor in your macOS menu bar.
//
// Reads the Aranet4's BLE advertisement (company ID 0x0702) and shows CO2,
// temperature, humidity, pressure and battery. It never opens a GATT
// connection, so it costs no battery and does not steal the link from the
// Aranet phone app.
//
// Usage:
//   ./aranetbar.swift                # run as a menu bar app
//   ./aranetbar.swift --verbose      # run with logging
//   ./aranetbar.swift --once         # print one reading and exit (for testing)
//
import Cocoa
import CoreBluetooth

// MARK: - Protocol

struct AranetReading {
    var co2: Int
    var temperatureC: Double
    var pressureHpa: Double
    var humidity: Int
    var battery: Int
    var status: Int
    var interval: Int
    var age: Int
    var rssi: Int
    var receivedAt: Date

    var temperatureF: Double { temperatureC * 9.0 / 5.0 + 32.0 }

    /// Age of the measurement in seconds, projected to now.
    var effectiveAge: Int { age + Int(Date().timeIntervalSince(receivedAt)) }

    var isStale: Bool { interval > 0 && effectiveAge > interval + interval / 2 }

    var statusName: String {
        switch status {
        case 0: return "Error"
        case 1: return "Green"
        case 2: return "Yellow"
        case 3: return "Red"
        default: return "Unknown"
        }
    }

    var statusColor: NSColor {
        switch status {
        case 1: return .systemGreen
        case 2: return .systemYellow
        case 3: return .systemRed
        default: return .systemGray
        }
    }
}

enum AranetProtocol {
    /// Aranet's Bluetooth SIG company identifier.
    static let companyID: UInt16 = 0x0702

    static let serviceUUID = CBUUID(string: "0000FCE0-0000-1000-8000-00805F9B34FB")
    /// 13-byte full reading; only needed if we ever switch to a GATT read.
    static let currentCharacteristic = CBUUID(string: "F0CD3001-95DA-4F4B-9AC8-AA55D312AF0C")

    // Advertisement payload layout, after the 2-byte company ID:
    //   [0..7]   header
    //   [8..18]  11-byte reading (CO2, temp, pressure, humidity, battery,
    //            status, interval) -- same struct as the GATT characteristic
    //   [19..20] age of the measurement, seconds
    //   [21]     trailer
    static let advReadingOffset = 8
    static let advAgeOffset = 19
    static let advReadingLength = 11

    /// Decode CoreBluetooth's manufacturer data (`CBCentralManager` prefixes the
    /// company ID, so the payload we care about starts at byte 2).
    static func reading(fromManufacturerData data: Data, rssi: Int) -> AranetReading? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }

        let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard company == companyID else { return nil }

        let payload = Array(bytes[2...])
        guard payload.count >= advAgeOffset + 2 else { return nil }

        let body = Array(payload[advReadingOffset ..< advReadingOffset + advReadingLength])
        let age = u16(payload, advAgeOffset)
        return decode13(body + [UInt8(age & 0xFF), UInt8(age >> 8)], rssi: rssi)
    }

    /// Decode the canonical 13-byte reading (little endian).
    static func decode13(_ b: [UInt8], rssi: Int = 0) -> AranetReading? {
        guard b.count >= 13 else { return nil }

        let co2 = u16(b, 0)
        let temperatureC = Double(u16(b, 2)) / 20.0

        // Reject implausible values: that means we mis-parsed a foreign packet,
        // which is better than displaying nonsense in the menu bar.
        guard co2 <= 9999, temperatureC > -40, temperatureC < 80 else { return nil }

        return AranetReading(
            co2: co2,
            temperatureC: temperatureC,
            pressureHpa: Double(u16(b, 4)) / 10.0,
            humidity: Int(b[6]),
            battery: Int(b[7]),
            status: Int(b[8]),
            interval: u16(b, 9),
            age: u16(b, 11),
            rssi: rssi,
            receivedAt: Date()
        )
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }
}

// MARK: - App

final class AranetBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var central: CBCentralManager?
    private var reading: AranetReading?
    private var deviceName: String?
    private var verbose = false
    private var oneshot = false
    private var dumpMenu = false
    private var lastLoggedSignature: String?

    // Scanning is duty-cycled: the sensor only logs every `interval` seconds
    // (5 min by default), so there is no point keeping the radio busy forever.
    private let scanWindow: TimeInterval = 5
    private let scanPeriod: TimeInterval = 20
    private var isScanning = false
    private var cycleTimer: Timer?
    private var ticker: Timer?
    private var onceTimeout: Timer?

    private var useFahrenheit: Bool {
        get { UserDefaults.standard.bool(forKey: "useFahrenheit") }
        set { UserDefaults.standard.set(newValue, forKey: "useFahrenheit") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        verbose = args.contains("--verbose") || args.contains("-v")
        oneshot = args.contains("--once")
        dumpMenu = args.contains("--dump-menu")

        log("🚀 aranetbar starting")

        if !oneshot {
            setupStatusItem()
            setupMenu()
        }

        // nil queue => delegate callbacks land on the main queue, which is what
        // we want for UI updates.
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )

        if oneshot || dumpMenu {
            // Fail rather than hang if the meter is not around.
            onceTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in
                FileHandle.standardError.write(Data("No Aranet4 advertisement seen.\n".utf8))
                exit(1)
            }
        } else {
            // Re-render periodically so staleness is reflected in the title.
            ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.updateTitle()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◌"
        log("🔧 status item created")
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("🔵 central state = \(central.state.rawValue)")

        switch central.state {
        case .poweredOn:
            if oneshot || dumpMenu {
                beginScan()
            } else {
                startScanCycle()
            }
        case .unauthorized:
            log("❌ Bluetooth permission denied")
            if !oneshot { showError("Bluetooth permission denied") }
        case .poweredOff:
            if !oneshot { showError("Bluetooth is off") }
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        else { return }

        // The company ID check plus plausibility check in the parser is a
        // stronger filter than name matching, and it still works when macOS
        // hands us a peripheral with no cached name.
        guard let parsed = AranetProtocol.reading(
            fromManufacturerData: manufacturerData,
            rssi: RSSI.intValue
        ) else { return }

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        if let name, !name.isEmpty { deviceName = name }

        let previous = reading
        reading = parsed

        // Several advertisements arrive per measurement; only log real changes
        // so the log stays readable (rssi jitter is deliberately ignored).
        let signature = "\(parsed.co2)|\(parsed.temperatureC)|\(parsed.humidity)|\(parsed.age)"
        if signature != lastLoggedSignature {
            lastLoggedSignature = signature
            log(
                "📡 \(deviceName ?? "Aranet4"): CO2 \(parsed.co2) ppm, "
                    + String(format: "%.2f C, %.1f hPa, ", parsed.temperatureC, parsed.pressureHpa)
                    + "RH \(parsed.humidity)%, bat \(parsed.battery)%, "
                    + "status \(parsed.statusName), age \(parsed.age)s, rssi \(parsed.rssi)"
            )
        }

        if dumpMenu {
            onceTimeout?.invalidate()
            printDump()
            exit(0)
        }

        if oneshot {
            onceTimeout?.invalidate()
            printReading(parsed)
            exit(0)
        }

        // Only touch the menu bar when the numbers actually move.
        if previous?.co2 != parsed.co2
            || previous?.temperatureC != parsed.temperatureC
            || previous?.humidity != parsed.humidity
            || previous == nil
        {
            updateTitle()
        }
    }

    // MARK: Scanning

    private func startScanCycle() {
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: scanPeriod, repeats: true) {
            [weak self] _ in
            self?.beginScan()
        }
        beginScan()
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, !isScanning else { return }
        isScanning = true
        log("🔍 scanning for \(Int(scanWindow))s")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            self?.endScan()
        }
    }

    private func endScan() {
        guard isScanning else { return }
        isScanning = false
        central?.stopScan()
        log("⏹ scan stopped")
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        // Header
        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(
            string: "ARANET4 · \(deviceName ?? "searching…")",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ]
        )
        header.isEnabled = true
        menu.addItem(header)
        menu.addItem(.separator())

        guard let r = reading else {
            menu.addItem(info("Waiting for the meter", "—"))
            menu.addItem(.separator())
            addActions(to: menu)
            return
        }

        // The preferred unit leads; the other stays visible so the row is never
        // ambiguous. This is what the "Show Fahrenheit" toggle actually changes.
        let temperature = useFahrenheit
            ? String(format: "%.1f °F  ·  %.1f °C", r.temperatureF, r.temperatureC)
            : String(format: "%.1f °C  ·  %.1f °F", r.temperatureC, r.temperatureF)

        menu.addItem(info("CO₂", "\(r.co2) ppm", color: r.statusColor))
        menu.addItem(info("Temperature", temperature))
        menu.addItem(info("Humidity", "\(r.humidity) %"))
        menu.addItem(info("Pressure", String(format: "%.1f hPa", r.pressureHpa)))
        menu.addItem(info("Battery", "\(r.battery) %"))
        menu.addItem(.separator())
        menu.addItem(info("Status", r.statusName))
        menu.addItem(info("Signal", "\(r.rssi) dBm"))
        menu.addItem(info("Measured", "\(r.effectiveAge)s ago  ·  every \(r.interval)s"))
        menu.addItem(.separator())
        addActions(to: menu)
    }

    private func addActions(to menu: NSMenu) {
        let fahrenheit = NSMenuItem(
            title: "Show Fahrenheit",
            action: #selector(toggleFahrenheit),
            keyEquivalent: ""
        )
        fahrenheit.target = self
        fahrenheit.state = useFahrenheit ? .on : .off
        menu.addItem(fahrenheit)

        let rescan = NSMenuItem(title: "Rescan Now", action: #selector(rescanNow), keyEquivalent: "r")
        rescan.target = self
        menu.addItem(rescan)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AranetBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// A non-clickable data row that keeps its colours (hence isEnabled = true
    /// together with autoenablesItems = false).
    private func info(_ label: String, _ value: String, color: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem()
        let text = NSMutableAttributedString(
            string: label,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 12),
            ]
        )
        text.append(NSAttributedString(string: "    "))
        text.append(
            NSAttributedString(
                string: value,
                attributes: [
                    .foregroundColor: color ?? NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                ]
            )
        )
        item.attributedTitle = text
        item.isEnabled = true
        item.action = nil
        return item
    }

    // MARK: Title

    private func updateTitle() {
        guard let button = statusItem?.button else { return }

        guard let r = reading else {
            button.attributedTitle = NSAttributedString(
                string: "◌",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            )
            return
        }

        let stale = r.isStale
        let text = NSMutableAttributedString(
            string: "●  ",
            attributes: [
                .foregroundColor: stale ? NSColor.tertiaryLabelColor : r.statusColor,
                .font: NSFont.systemFont(ofSize: 9),
            ]
        )
        text.append(
            NSAttributedString(
                string: "\(r.co2)",
                attributes: [
                    .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                ]
            )
        )
        button.attributedTitle = text
    }

    private func showError(_ message: String) {
        reading = nil
        statusItem?.button?.attributedTitle = NSAttributedString(
            string: "⚠︎",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        log("❌ \(message)")
    }

    // MARK: Actions

    @objc private func toggleFahrenheit() {
        useFahrenheit.toggle()
        log("🌡 fahrenheit = \(useFahrenheit)")
    }

    @objc private func rescanNow() {
        log("🔁 manual rescan")
        beginScan()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: Output

    private func printReading(_ r: AranetReading) {
        let line = String(
            format: "CO2 %d ppm | %.2f C / %.2f F | %.1f hPa | RH %d%% | bat %d%% | %@ | age %ds/%ds | rssi %d dBm",
            r.co2, r.temperatureC, r.temperatureF, r.pressureHpa,
            r.humidity, r.battery, r.statusName, r.age, r.interval, r.rssi
        )
        print(line)
    }

    private func log(_ message: String) {
        guard verbose else { return }
        print(message)
        // stdout is block-buffered when piped; flush so a killed process still
        // leaves a usable log behind.
        fflush(stdout)
    }

    /// `--dump-menu` renders the real menu off-screen and prints it as text.
    /// Useful for verifying the UI without a screenshot.
    private func printDump() {
        updateTitle()
        print("TITLE: \(statusItem?.button?.attributedTitle.string ?? "(none)")")

        let preview = NSMenu()
        populate(preview)
        for item in preview.items {
            if item.isSeparatorItem {
                print("  ---")
            } else {
                let title = item.attributedTitle?.string ?? item.title
                let checked = item.state == .on ? "  [checked]" : ""
                print("  \(title)\(checked)")
            }
        }
        fflush(stdout)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AranetBarApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
