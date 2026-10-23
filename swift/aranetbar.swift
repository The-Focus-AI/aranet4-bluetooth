#!/usr/bin/env swift
//
// AranetBar
// Aranet4 CO2 monitor in your macOS menu bar.
//
// Reads the Aranet4's BLE advertisement (company ID 0x0702) and shows CO2,
// temperature, humidity, pressure and battery. Live data never opens a GATT
// connection, so it costs no battery and does not steal the link from the
// Aranet phone app. The History window downloads the meter's on-board log
// over GATT on demand (see PROTOCOL.md §6).
//
// Usage:
//   ./aranetbar.swift                # run as a menu bar app
//   ./aranetbar.swift --verbose      # run with logging
//   ./aranetbar.swift --once         # print one reading and exit (for testing)
//   ./aranetbar.swift --dump-menu    # render the menu as text and exit
//   ./aranetbar.swift --history      # download the log headlessly
//   ./aranetbar.swift --history --history-csv out.csv --history-json out.json
//   ./aranetbar.swift --history --history-days 7
//   ./aranetbar.swift --render-history chart.png   # from the cached snapshot
//
import Cocoa
@preconcurrency import CoreBluetooth
import UniformTypeIdentifiers

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

    // History (see PROTOCOL.md §6). These are only touched when the user opens
    // the history window -- the live menu bar keeps using advertisements.
    static let totalCharacteristic = CBUUID(string: "F0CD2001-95DA-4F4B-9AC8-AA55D312AF0C")
    static let intervalCharacteristic = CBUUID(string: "F0CD2002-95DA-4F4B-9AC8-AA55D312AF0C")
    static let historyCharacteristic = CBUUID(string: "F0CD2005-95DA-4F4B-9AC8-AA55D312AF0C")
    static let commandCharacteristic = CBUUID(string: "F0CD1402-95DA-4F4B-9AC8-AA55D312AF0C")

    static let deviceInformationService = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
    static let serialCharacteristic = CBUUID(string: "00002A25-0000-1000-8000-00805F9B34FB")
    static let firmwareCharacteristic = CBUUID(string: "00002A26-0000-1000-8000-00805F9B34FB")

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

// MARK: - History model

struct HistorySample: Codable {
    var date: Date
    var co2: Int?
    var temperatureC: Double?
    var humidity: Int?
    var pressureHpa: Double?
}

struct HistorySnapshot: Codable {
    var deviceName: String
    var serial: String
    var firmware: String
    var intervalSeconds: Int
    var totalRecords: Int
    var downloadedAt: Date
    var samples: [HistorySample]
    var warnings: [String]

    var dateRange: ClosedRange<Date>? {
        guard let first = samples.first?.date, let last = samples.last?.date, first <= last
        else { return nil }
        return first ... last
    }
}

struct HistoryPage {
    var param: Int
    var interval: Int
    var total: Int
    var age: Int
    var start: Int
    var count: Int
    var values: [Int]
}

enum AranetHistoryProtocol {
    static let downloadOrder = [4, 3, 1, 2]
    static let paramNames = [1: "temperature", 2: "humidity", 3: "pressure", 4: "CO₂"]

    /// Decode one f0cd2005 page: 10-byte header plus u16 values (u8 for humidity).
    static func parsePage(_ data: Data) -> HistoryPage? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return nil }

        let param = Int(bytes[0])
        let interval = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let total = Int(bytes[3]) | (Int(bytes[4]) << 8)
        let age = Int(bytes[5]) | (Int(bytes[6]) << 8)
        let start = Int(bytes[7]) | (Int(bytes[8]) << 8)
        let count = Int(bytes[9])

        guard [1, 2, 3, 4].contains(param), count > 0 else { return nil }
        let size = param == 2 ? 1 : 2
        guard bytes.count >= 10 + count * size else { return nil }

        var values: [Int] = []
        values.reserveCapacity(count)
        for offset in 0..<count {
            if size == 1 {
                values.append(Int(bytes[10 + offset]))
            } else {
                let i = 10 + offset * 2
                values.append(Int(bytes[i]) | (Int(bytes[i + 1]) << 8))
            }
        }
        return HistoryPage(
            param: param, interval: interval, total: total, age: age,
            start: start, count: count, values: values
        )
    }

    /// Apply the device's scaling and sentinel bits (nil = no measurement).
    static func decode(param: Int, raw: Int) -> Double? {
        switch param {
        case 1:
            return (raw & 0x4000) != 0 ? nil : Double(raw) / 20.0
        case 2:
            return raw <= 100 ? Double(raw) : nil
        case 3:
            return (raw & 0x8000) != 0 ? nil : Double(raw) / 10.0
        case 4:
            return (raw & 0x8000) != 0 ? nil : Double(raw)
        default:
            return nil
        }
    }
}

enum HistoryStore {
    /// Overridable so headless tests do not write into the real user's Library.
    static var directoryURL: URL {
        if let override = ProcessInfo.processInfo.environment["ARANETBAR_SUPPORT_DIR"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AranetBar", isDirectory: true)
    }

    static var fileURL: URL { directoryURL.appendingPathComponent("history.json") }

    static func load() -> HistorySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HistorySnapshot.self, from: data)
    }

    static func save(_ snapshot: HistorySnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("AranetBar: could not save history: \(error.localizedDescription)")
        }
    }
}

enum HistoryError: LocalizedError {
    case bluetoothUnavailable
    case connectionFailed(String)
    case serviceMissing
    case characteristicMissing(String)
    case timeout(String)
    case malformed(String)
    case disconnected
    case noHistory

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is not available."
        case .connectionFailed(let detail):
            return "Couldn't connect to the meter: \(detail). "
                + "Another app may be using it."
        case .serviceMissing:
            return "The meter does not expose its history service."
        case .characteristicMissing(let name):
            return "The meter is missing its \(name) characteristic."
        case .timeout(let what):
            return "Timed out while \(what)."
        case .malformed(let what):
            return "Unexpected data from the meter while \(what)."
        case .disconnected:
            return "The meter disconnected before the download finished."
        case .noHistory:
            return "The meter returned no history pages."
        }
    }
}

// MARK: - History downloader

protocol HistoryDownloaderDelegate: AnyObject {
    func historyDownloader(_ downloader: HistoryDownloader, didProgress message: String)
    func historyDownloader(
        _ downloader: HistoryDownloader,
        didFinish result: Result<HistorySnapshot, Error>
    )
}

/// One GATT session that downloads the meter's ring buffer. It deliberately
/// connects only while the history window is refreshing; the menu bar itself
/// stays advertisement-only.
final class HistoryDownloader: NSObject, CBPeripheralDelegate {
    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?
    private weak var delegate: HistoryDownloaderDelegate?
    private let requestedDays: Double?

    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var readContinuation: (
        id: UUID, characteristic: CBUUID, continuation: CheckedContinuation<Data, Error>
    )?
    private var writeContinuation: (
        id: UUID, characteristic: CBUUID, continuation: CheckedContinuation<Void, Error>
    )?

    private var connectTimer: Timer?
    private var discoveryTimer: Timer?
    private var overallTimer: Timer?
    private var pendingServiceDiscoveries = 0
    private var connected = false
    private var finished = false

    init(
        peripheral: CBPeripheral,
        central: CBCentralManager,
        days: Double?,
        delegate: HistoryDownloaderDelegate?
    ) {
        self.peripheral = peripheral
        self.central = central
        self.requestedDays = days
        self.delegate = delegate
        super.init()
        peripheral.delegate = self
    }

    func start() {
        guard let central, central.state == .poweredOn else {
            finish(.failure(HistoryError.bluetoothUnavailable))
            return
        }
        connectTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) {
            [weak self] _ in
            self?.finish(.failure(HistoryError.timeout("connecting to the meter")))
        }
        central.connect(peripheral, options: nil)
    }

    /// Stop without reporting a result (window closed, app quitting, Bluetooth off).
    func cancel() {
        guard !finished else { return }
        finished = true
        invalidateTimers()
        failPending(HistoryError.disconnected)
        central?.cancelPeripheralConnection(peripheral)
    }

    // MARK: Central callbacks (forwarded by AranetBarApp)

    func didConnect() {
        guard !finished else { return }
        connectTimer?.invalidate()
        connected = true
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) {
            [weak self] _ in
            self?.finish(.failure(HistoryError.timeout("discovering the meter's services")))
        }
        peripheral.discoverServices([
            AranetProtocol.serviceUUID, AranetProtocol.deviceInformationService,
        ])
    }

    func didFailToConnect(_ error: Error?) {
        guard !finished else { return }
        let detail = error?.localizedDescription ?? "no response"
        finish(.failure(HistoryError.connectionFailed(detail)))
    }

    func didDisconnect(_ error: Error?) {
        guard !finished else { return }
        if let error {
            finish(.failure(HistoryError.connectionFailed(error.localizedDescription)))
        } else {
            finish(.failure(HistoryError.disconnected))
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !finished else { return }
        if let error {
            finish(.failure(error))
            return
        }
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == AranetProtocol.serviceUUID }) else {
            finish(.failure(HistoryError.serviceMissing))
            return
        }
        pendingServiceDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard !finished else { return }
        if let error, service.uuid == AranetProtocol.serviceUUID {
            finish(.failure(error))
            return
        }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        pendingServiceDiscoveries -= 1
        guard pendingServiceDiscoveries <= 0 else { return }

        discoveryTimer?.invalidate()
        let required: [(CBUUID, String)] = [
            (AranetProtocol.totalCharacteristic, "record count"),
            (AranetProtocol.intervalCharacteristic, "log interval"),
            (AranetProtocol.historyCharacteristic, "history"),
            (AranetProtocol.commandCharacteristic, "history command"),
        ]
        for (uuid, name) in required where characteristics[uuid] == nil {
            finish(.failure(HistoryError.characteristicMissing(name)))
            return
        }

        overallTimer = Timer.scheduledTimer(withTimeInterval: 150, repeats: false) {
            [weak self] _ in
            self?.finish(.failure(HistoryError.timeout("downloading the history log")))
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.download()
                self.finish(.success(snapshot))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let pending = readContinuation, pending.characteristic == characteristic.uuid
        else { return }
        readContinuation = nil
        if let error {
            pending.continuation.resume(throwing: error)
        } else if let data = characteristic.value {
            pending.continuation.resume(returning: data)
        } else {
            pending.continuation.resume(
                throwing: HistoryError.malformed("reading \(characteristic.uuid)")
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let pending = writeContinuation, pending.characteristic == characteristic.uuid
        else { return }
        writeContinuation = nil
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume()
        }
    }

    // MARK: Download

    private func download() async throws -> HistorySnapshot {
        let total = try await readU16(AranetProtocol.totalCharacteristic, name: "record count")
        let interval = try await readU16(
            AranetProtocol.intervalCharacteristic, name: "log interval"
        )
        let name = peripheral.name ?? "Aranet4"
        let serial = await readText(AranetProtocol.serialCharacteristic)
        let firmware = await readText(AranetProtocol.firmwareCharacteristic)

        guard total > 0 else {
            return HistorySnapshot(
                deviceName: name, serial: serial, firmware: firmware,
                intervalSeconds: interval, totalRecords: 0,
                downloadedAt: Date(), samples: [], warnings: []
            )
        }

        var start = 1
        if let days = requestedDays, days > 0, interval > 0 {
            let count = Int(ceil(days * 86_400.0 / Double(interval)))
            start = max(1, total - count + 1)
        }

        var series: [Int: [Int: Double]] = [:]
        var anchors: [Date] = []
        var warnings: [String] = []
        var pageTotal = total
        var pageInterval = interval

        for (offset, param) in AranetHistoryProtocol.downloadOrder.enumerated() {
            let label = AranetHistoryProtocol.paramNames[param] ?? "series \(param)"
            delegate?.historyDownloader(
                self, didProgress: "series \(offset + 1) of 4 (\(label))"
            )
            do {
                let fetched = try await fetchSeries(param: param, start: start, total: total)
                series[param] = fetched.values
                anchors.append(fetched.newest)
                pageTotal = max(pageTotal, fetched.total)
                if fetched.interval > 0 { pageInterval = fetched.interval }
            } catch {
                warnings.append("\(label): \(error.localizedDescription)")
            }
        }

        guard !anchors.isEmpty else { throw HistoryError.noHistory }
        guard pageInterval > 0 else {
            throw HistoryError.malformed("the meter reported a zero log interval")
        }

        let newest = anchors.sorted()[anchors.count / 2]
        let effectiveStart = min(start, pageTotal)
        var samples: [HistorySample] = []
        samples.reserveCapacity(max(0, pageTotal - effectiveStart + 1))
        for index in effectiveStart...pageTotal {
            let offset = Double(pageTotal - index) * Double(pageInterval)
            let timestamp = (newest.addingTimeInterval(-offset).timeIntervalSince1970).rounded()
            let sample = HistorySample(
                date: Date(timeIntervalSince1970: timestamp),
                co2: series[4]?[index].map { Int($0.rounded()) },
                temperatureC: series[1]?[index],
                humidity: series[2]?[index].map { Int($0.rounded()) },
                pressureHpa: series[3]?[index]
            )
            if sample.co2 == nil, sample.temperatureC == nil,
               sample.humidity == nil, sample.pressureHpa == nil
            {
                continue
            }
            samples.append(sample)
        }

        return HistorySnapshot(
            deviceName: name, serial: serial, firmware: firmware,
            intervalSeconds: pageInterval, totalRecords: pageTotal,
            downloadedAt: Date(), samples: samples, warnings: warnings
        )
    }

    private func fetchSeries(
        param: Int, start: Int, total: Int
    ) async throws -> (values: [Int: Double], newest: Date, total: Int, interval: Int) {
        guard let command = characteristics[AranetProtocol.commandCharacteristic],
              let history = characteristics[AranetProtocol.historyCharacteristic]
        else {
            throw HistoryError.characteristicMissing("history")
        }

        let commandBytes = Data([
            0x61, UInt8(param),
            UInt8(start & 0xFF), UInt8((start >> 8) & 0xFF),
        ])
        try await write(commandBytes, to: command, timeout: 5)

        var values: [Int: Double] = [:]
        var newest: Date?
        var pageTotal = total
        var pageInterval = 0
        let deadline = Date().addingTimeInterval(20)

        while Date() < deadline {
            try Task.checkCancellation()
            let packet = try await read(history, timeout: 4)
            guard let page = AranetHistoryProtocol.parsePage(packet),
                  page.param == param, page.count > 0
            else {
                try await sleep(milliseconds: 100)
                continue
            }

            if newest == nil {
                newest = Date().addingTimeInterval(-Double(page.age))
                pageTotal = page.total > 0 ? page.total : total
                pageInterval = page.interval
            }
            for offset in 0..<page.count {
                let index = page.start + offset
                guard index >= start, index <= pageTotal,
                      offset < page.values.count,
                      let value = AranetHistoryProtocol.decode(
                          param: param, raw: page.values[offset]
                      )
                else { continue }
                values[index] = value
            }

            if page.start + page.count - 1 >= pageTotal {
                return (values, newest ?? Date(), pageTotal, pageInterval)
            }
        }
        throw HistoryError.timeout(
            "waiting for the \(AranetHistoryProtocol.paramNames[param] ?? "history") series"
        )
    }

    // MARK: GATT plumbing

    private func readU16(_ uuid: CBUUID, name: String) async throws -> Int {
        let data = try await read(characteristic(uuid), timeout: 5)
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            throw HistoryError.malformed("reading the \(name)")
        }
        return Int(bytes[0]) | (Int(bytes[1]) << 8)
    }

    private func readText(_ uuid: CBUUID) async -> String {
        guard let characteristic = characteristics[uuid] else { return "" }
        guard let data = try? await read(characteristic, timeout: 3) else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private func characteristic(_ uuid: CBUUID) throws -> CBCharacteristic {
        guard let characteristic = characteristics[uuid] else {
            throw HistoryError.characteristicMissing(uuid.uuidString)
        }
        return characteristic
    }

    private func read(
        _ characteristic: CBCharacteristic, timeout: TimeInterval
    ) async throws -> Data {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            guard !finished else {
                continuation.resume(throwing: HistoryError.disconnected)
                return
            }
            guard readContinuation == nil else {
                continuation.resume(throwing: HistoryError.malformed("overlapping reads"))
                return
            }
            readContinuation = (id, characteristic.uuid, continuation)
            peripheral.readValue(for: characteristic)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.finished,
                      let pending = self.readContinuation, pending.id == id
                else { return }
                self.readContinuation = nil
                pending.continuation.resume(
                    throwing: HistoryError.timeout("reading \(characteristic.uuid)")
                )
            }
        }
    }

    private func write(
        _ data: Data, to characteristic: CBCharacteristic, timeout: TimeInterval
    ) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !finished else {
                continuation.resume(throwing: HistoryError.disconnected)
                return
            }
            guard writeContinuation == nil else {
                continuation.resume(throwing: HistoryError.malformed("overlapping writes"))
                return
            }
            writeContinuation = (id, characteristic.uuid, continuation)
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.finished,
                      let pending = self.writeContinuation, pending.id == id
                else { return }
                self.writeContinuation = nil
                pending.continuation.resume(
                    throwing: HistoryError.timeout("writing to \(characteristic.uuid)")
                )
            }
        }
    }

    private func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private func invalidateTimers() {
        connectTimer?.invalidate()
        discoveryTimer?.invalidate()
        overallTimer?.invalidate()
        connectTimer = nil
        discoveryTimer = nil
        overallTimer = nil
    }

    private func failPending(_ error: Error) {
        if let pending = readContinuation {
            readContinuation = nil
            pending.continuation.resume(throwing: error)
        }
        if let pending = writeContinuation {
            writeContinuation = nil
            pending.continuation.resume(throwing: error)
        }
    }

    private func finish(_ result: Result<HistorySnapshot, Error>) {
        guard !finished else { return }
        finished = true
        invalidateTimers()
        if case .failure(let error) = result {
            failPending(error)
        }
        if connected {
            central?.cancelPeripheralConnection(peripheral)
        }
        delegate?.historyDownloader(self, didFinish: result)
    }
}

// MARK: - CSV export

enum HistoryCSV {
    static func write(_ snapshot: HistorySnapshot, to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current

        var lines = ["timestamp,co2_ppm,temperature_c,humidity_pct,pressure_hpa,epoch_s"]
        lines.reserveCapacity(snapshot.samples.count + 1)
        for sample in snapshot.samples {
            let co2 = sample.co2.map(String.init) ?? ""
            let temperature = sample.temperatureC.map(compact) ?? ""
            let humidity = sample.humidity.map(String.init) ?? ""
            let pressure = sample.pressureHpa.map(compact) ?? ""
            let epoch = Int(sample.date.timeIntervalSince1970)
            lines.append(
                "\(formatter.string(from: sample.date)),\(co2),\(temperature),"
                    + "\(humidity),\(pressure),\(epoch)"
            )
        }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private static func compact(_ value: Double) -> String {
        if value.rounded() == value { return String(format: "%.0f", value) }
        if (value * 10).rounded() == value * 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

// MARK: - History chart

enum HistoryRange: Int, CaseIterable {
    case day = 0
    case week = 1
    case all = 2

    var title: String {
        switch self {
        case .day: return "24 h"
        case .week: return "7 days"
        case .all: return "All"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .all: return nil
        }
    }
}

enum HistoryMetric: CaseIterable {
    case co2
    case temperature
    case humidity
    case pressure

    func title(fahrenheit: Bool) -> String {
        switch self {
        case .co2: return "CO₂ (ppm)"
        case .temperature: return fahrenheit ? "Temperature (°F)" : "Temperature (°C)"
        case .humidity: return "Humidity (%)"
        case .pressure: return "Pressure (hPa)"
        }
    }

    var color: NSColor {
        switch self {
        case .co2: return .systemBlue
        case .temperature: return .systemOrange
        case .humidity: return .systemTeal
        case .pressure: return .systemPurple
        }
    }

    func value(_ sample: HistorySample, fahrenheit: Bool) -> Double? {
        switch self {
        case .co2: return sample.co2.map(Double.init)
        case .temperature:
            guard let celsius = sample.temperatureC else { return nil }
            return fahrenheit ? celsius * 9.0 / 5.0 + 32.0 : celsius
        case .humidity: return sample.humidity.map(Double.init)
        case .pressure: return sample.pressureHpa
        }
    }

    func axisLabel(_ value: Double, fahrenheit: Bool) -> String {
        if abs(value - value.rounded()) < 0.001 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    func shortLabel(_ value: Double, fahrenheit: Bool) -> String {
        switch self {
        case .co2, .humidity:
            return String(format: "%.0f", value)
        case .temperature, .pressure:
            return String(format: "%.1f", value)
        }
    }

    func valueLabel(_ value: Double, fahrenheit: Bool) -> String {
        switch self {
        case .co2: return "\(Int(value.rounded())) ppm"
        case .temperature:
            return String(format: fahrenheit ? "%.1f °F" : "%.1f °C", value)
        case .humidity: return "\(Int(value.rounded())) %"
        case .pressure: return String(format: "%.1f hPa", value)
        }
    }
}

private struct HistoryChartLayout {
    let samples: [HistorySample]
    let start: Date
    let end: Date
    let outer: NSRect
    let plotX: CGFloat
    let plotWidth: CGFloat
    let panelHeight: CGFloat
    let gap: CGFloat
    let headerHeight: CGFloat
    let xAxisHeight: CGFloat

    func plotRect(panel index: Int) -> NSRect {
        let top = outer.minY + CGFloat(index) * (panelHeight + gap)
        return NSRect(
            x: plotX, y: top + headerHeight,
            width: plotWidth, height: panelHeight - headerHeight
        )
    }

    func headerRect(panel index: Int) -> NSRect {
        let top = outer.minY + CGFloat(index) * (panelHeight + gap)
        return NSRect(x: outer.minX, y: top, width: outer.width, height: headerHeight)
    }

    func x(for date: Date) -> CGFloat {
        let span = max(end.timeIntervalSince(start), 1)
        let fraction = date.timeIntervalSince(start) / span
        return plotX + CGFloat(min(max(fraction, 0), 1)) * plotWidth
    }

    func date(atX x: CGFloat) -> Date {
        let fraction = min(max((x - plotX) / max(plotWidth, 1), 0), 1)
        return start.addingTimeInterval(Double(fraction) * end.timeIntervalSince(start))
    }
}

final class HistoryChartView: NSView {
    var snapshot: HistorySnapshot? {
        didSet {
            hoverDate = nil
            hoverPoint = nil
            needsDisplay = true
        }
    }
    var range: HistoryRange = .all {
        didSet {
            zoomedRange = nil
            hoverDate = nil
            onZoomStateChanged?(false)
            needsDisplay = true
        }
    }
    var useFahrenheit = false {
        didSet { needsDisplay = true }
    }
    var statusMessage = "No history yet" {
        didSet { needsDisplay = true }
    }
    /// Called with true while the user has scrolled/pinched away from the
    /// selected range, and false when the range is restored.
    var onZoomStateChanged: ((Bool) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverDate: Date?
    private var hoverPoint: NSPoint?
    private var zoomedRange: (start: Date, end: Date)?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM · HH:mm"
        return formatter
    }()

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        guard let layout = makeLayout() else {
            drawEmptyState()
            return
        }

        let ticks = xTicks(layout: layout)

        for (index, metric) in HistoryMetric.allCases.enumerated() {
            drawPanel(metric, index: index, layout: layout, ticks: ticks)
        }
        drawXAxis(layout: layout, ticks: ticks)
        drawHover(layout: layout)
    }

    private func makeLayout() -> HistoryChartLayout? {
        guard let snapshot, !snapshot.samples.isEmpty,
              let first = snapshot.samples.first?.date,
              let last = snapshot.samples.last?.date
        else { return nil }

        let fullStart = first
        let fullEnd = last
        let start: Date
        let end: Date
        if let zoomed = zoomedRange,
           zoomed.end > fullStart, zoomed.start < fullEnd,
           zoomed.end.timeIntervalSince(zoomed.start) > 1
        {
            start = max(zoomed.start, fullStart)
            end = min(zoomed.end, fullEnd)
        } else {
            if let seconds = range.seconds {
                start = max(fullStart, fullEnd.addingTimeInterval(-seconds))
            } else {
                start = fullStart
            }
            end = fullEnd
        }
        let samples = snapshot.samples.filter { $0.date >= start && $0.date <= end }
        guard !samples.isEmpty else { return nil }

        let inset = NSEdgeInsets(top: 8, left: 12, bottom: 6, right: 14)
        let outer = NSRect(
            x: bounds.minX + inset.left,
            y: bounds.minY + inset.top,
            width: bounds.width - inset.left - inset.right,
            height: bounds.height - inset.top - inset.bottom
        )
        let axisWidth: CGFloat = 52
        let xAxisHeight: CGFloat = 24
        let gap: CGFloat = 14
        let headerHeight: CGFloat = 22
        let panelHeight = (outer.height - xAxisHeight - gap * 3) / 4
        guard panelHeight > 46, outer.width > 240 else { return nil }

        return HistoryChartLayout(
            samples: samples,
            start: start,
            end: max(end, start.addingTimeInterval(1)),
            outer: outer,
            plotX: outer.minX + axisWidth,
            plotWidth: outer.width - axisWidth - 6,
            panelHeight: panelHeight,
            gap: gap,
            headerHeight: headerHeight,
            xAxisHeight: xAxisHeight
        )
    }

    // MARK: Zoom

    /// Zoom around the cursor. `factor > 1` zooms in; the visible time span is
    /// divided by it, so the anchor keeps its position under the pointer.
    private func zoom(by factor: Double, at point: NSPoint) {
        guard factor > 0, factor.isFinite,
              let snapshot,
              let layout = makeLayout(),
              let fullStart = snapshot.samples.first?.date,
              let fullEnd = snapshot.samples.last?.date
        else { return }

        let currentSpan = layout.end.timeIntervalSince(layout.start)
        guard currentSpan > 0 else { return }
        let fullSpan = fullEnd.timeIntervalSince(fullStart)
        guard fullSpan > 0 else { return }

        let minimumSpan = max(Double(max(snapshot.intervalSeconds, 1)) * 3, 15 * 60)
        let targetSpan = min(max(currentSpan / factor, minimumSpan), fullSpan)
        guard abs(targetSpan - currentSpan) > 0.5 else { return }

        let clampedX = min(max(point.x, layout.plotX), layout.plotX + layout.plotWidth)
        let anchor = layout.date(atX: clampedX)
        let fraction = min(
            max(anchor.timeIntervalSince(layout.start) / currentSpan, 0), 1
        )

        var start = anchor.addingTimeInterval(-fraction * targetSpan)
        var end = start.addingTimeInterval(targetSpan)
        if start < fullStart {
            start = fullStart
            end = start.addingTimeInterval(targetSpan)
        }
        if end > fullEnd {
            end = fullEnd
            start = end.addingTimeInterval(-targetSpan)
        }

        // Zooming all the way out is the same as resetting.
        if start <= fullStart.addingTimeInterval(1),
           end >= fullEnd.addingTimeInterval(-1)
        {
            resetZoom()
            return
        }

        zoomedRange = (start, end)
        hoverDate = nil
        onZoomStateChanged?(true)
        needsDisplay = true
    }

    /// Shift the visible window through time. Positive x (scrolling right)
    /// moves towards older readings, matching a timeline you drag sideways.
    private func pan(by deltaX: Double, layout: HistoryChartLayout, precise: Bool) {
        guard let snapshot,
              let fullStart = snapshot.samples.first?.date,
              let fullEnd = snapshot.samples.last?.date
        else { return }

        let span = layout.end.timeIntervalSince(layout.start)
        let fullSpan = fullEnd.timeIntervalSince(fullStart)
        guard span > 0, fullSpan - span > 1 else { return }

        var fraction = precise
            ? deltaX / Double(max(layout.plotWidth, 1))
            : deltaX * 0.05
        fraction = min(max(fraction, -0.2), 0.2)
        guard abs(fraction) > 0.0001 else { return }

        let shift = span * fraction
        var start = layout.start.addingTimeInterval(-shift)
        var end = layout.end.addingTimeInterval(-shift)
        if start < fullStart {
            start = fullStart
            end = start.addingTimeInterval(span)
        }
        if end > fullEnd {
            end = fullEnd
            start = end.addingTimeInterval(-span)
        }
        guard abs(start.timeIntervalSince(layout.start)) > 0.5 else { return }

        zoomedRange = (start, end)
        hoverDate = nil
        onZoomStateChanged?(true)
        needsDisplay = true
    }

    private func resetZoom() {
        guard zoomedRange != nil else { return }
        zoomedRange = nil
        hoverDate = nil
        onZoomStateChanged?(false)
        needsDisplay = true
    }

    private func drawEmptyState() {
        let text = statusMessage
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    private func drawPanel(
        _ metric: HistoryMetric, index: Int, layout: HistoryChartLayout, ticks: [Date]
    ) {
        let plot = layout.plotRect(panel: index)
        let header = layout.headerRect(panel: index)

        var points: [(Date, Double)] = []
        for sample in layout.samples {
            if let value = metric.value(sample, fahrenheit: useFahrenheit) {
                points.append((sample.date, value))
            }
        }
        drawText(
            metric.title(fahrenheit: useFahrenheit),
            at: NSPoint(x: header.minX, y: header.minY + 1),
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
        guard !points.isEmpty else {
            drawText(
                "No data in this range",
                at: NSPoint(x: header.maxX, y: header.minY + 2),
                font: .systemFont(ofSize: 10),
                color: .tertiaryLabelColor,
                alignment: .right
            )
            return
        }

        let values = points.map(\.1)
        let (low, high, step) = scale(for: values)
        let average = values.reduce(0, +) / Double(values.count)
        let stats = "\(metric.shortLabel(values.min() ?? 0, fahrenheit: useFahrenheit))"
            + "–\(metric.shortLabel(values.max() ?? 0, fahrenheit: useFahrenheit))"
            + " · avg \(metric.shortLabel(average, fahrenheit: useFahrenheit))"
            + " · last \(metric.shortLabel(values.last ?? 0, fahrenheit: useFahrenheit))"
        drawText(
            stats,
            at: NSPoint(x: header.maxX, y: header.minY + 2),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            color: .secondaryLabelColor,
            alignment: .right
        )

        // Horizontal grid and y labels.
        let tickCount = max(1, Int(round((high - low) / step)))
        for tick in 0...tickCount {
            let value = low + Double(tick) * step
            let y = plot.maxY - CGFloat((value - low) / max(high - low, 1)) * plot.height
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.lineWidth = 0.5
            NSColor.gridColor.withAlphaComponent(0.45).setStroke()
            grid.stroke()

            drawText(
                metric.axisLabel(value, fahrenheit: useFahrenheit),
                at: NSPoint(x: plot.minX - 8, y: y - 6),
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                color: .tertiaryLabelColor,
                alignment: .right
            )
        }

        // Vertical grid shared by every panel.
        for date in ticks {
            let x = layout.x(for: date)
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: x, y: plot.minY))
            grid.line(to: NSPoint(x: x, y: plot.maxY))
            grid.lineWidth = 0.5
            NSColor.gridColor.withAlphaComponent(0.35).setStroke()
            grid.stroke()
        }

        // Unit thresholds make the CO₂ panel readable at a glance.
        if metric == .co2 {
            for threshold in [800.0, 1000.0] where threshold > low && threshold < high {
                let y = plot.maxY - CGFloat((threshold - low) / max(high - low, 1)) * plot.height
                let line = NSBezierPath()
                line.move(to: NSPoint(x: plot.minX, y: y))
                line.line(to: NSPoint(x: plot.maxX, y: y))
                line.setLineDash([4, 3], count: 2, phase: 0)
                line.lineWidth = 0.7
                NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
                line.stroke()
                drawText(
                    "\(Int(threshold))",
                    at: NSPoint(x: plot.maxX - 3, y: y - 10),
                    font: .monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                    color: .secondaryLabelColor,
                    alignment: .right
                )
            }
        }

        drawSeries(
            metric: metric, samples: layout.samples, plot: plot,
            layout: layout, low: low, high: high
        )
    }

    private func drawSeries(
        metric: HistoryMetric, samples: [HistorySample], plot: NSRect,
        layout: HistoryChartLayout, low: Double, high: Double
    ) {
        var segments: [[(Date, Double)]] = []
        var current: [(Date, Double)] = []
        for sample in samples {
            if let value = metric.value(sample, fahrenheit: useFahrenheit) {
                current.append((sample.date, value))
            } else if !current.isEmpty {
                segments.append(current)
                current = []
            }
        }
        if !current.isEmpty { segments.append(current) }

        func y(for value: Double) -> CGFloat {
            plot.maxY - CGFloat((value - low) / max(high - low, 1)) * plot.height
        }

        for segment in segments where segment.count > 1 {
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: layout.x(for: segment[0].0), y: plot.maxY))
            for (date, value) in segment {
                fill.line(to: NSPoint(x: layout.x(for: date), y: y(for: value)))
            }
            fill.line(to: NSPoint(x: layout.x(for: segment[segment.count - 1].0), y: plot.maxY))
            fill.close()
            metric.color.withAlphaComponent(0.10).setFill()
            fill.fill()

            let line = NSBezierPath()
            for (index, point) in segment.enumerated() {
                let position = NSPoint(x: layout.x(for: point.0), y: y(for: point.1))
                if index == 0 { line.move(to: position) } else { line.line(to: position) }
            }
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            metric.color.setStroke()
            line.stroke()
        }

        // A single isolated reading still deserves a mark.
        for segment in segments where segment.count == 1 {
            let point = segment[0]
            let dot = NSBezierPath(
                ovalIn: NSRect(
                    x: layout.x(for: point.0) - 2, y: y(for: point.1) - 2,
                    width: 4, height: 4
                )
            )
            metric.color.setFill()
            dot.fill()
        }

        if let last = segments.last?.last {
            let dot = NSBezierPath(
                ovalIn: NSRect(
                    x: layout.x(for: last.0) - 2.5, y: y(for: last.1) - 2.5,
                    width: 5, height: 5
                )
            )
            metric.color.setFill()
            dot.fill()
        }
    }

    private func drawXAxis(layout: HistoryChartLayout, ticks: [Date]) {
        let y = layout.outer.maxY - layout.xAxisHeight + 6
        for date in ticks {
            drawText(
                dateLabel(date, span: layout.end.timeIntervalSince(layout.start)),
                at: NSPoint(x: layout.x(for: date), y: y),
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                color: .secondaryLabelColor,
                alignment: .center
            )
        }
    }

    private func drawHover(layout: HistoryChartLayout) {
        guard let hoverDate, let hoverPoint,
              let sample = nearestSample(to: hoverDate, in: layout.samples)
        else { return }

        let x = layout.x(for: sample.date)
        for index in HistoryMetric.allCases.indices {
            let plot = layout.plotRect(panel: index)
            guard x >= plot.minX - 1, x <= plot.maxX + 1 else { continue }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plot.minY))
            line.line(to: NSPoint(x: x, y: plot.maxY))
            line.lineWidth = 0.8
            NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
            line.stroke()
        }

        let dateText = Self.tooltipFormatter.string(from: sample.date)
        var parts = [dateText]
        for metric in HistoryMetric.allCases {
            if let value = metric.value(sample, fahrenheit: useFahrenheit) {
                parts.append(metric.valueLabel(value, fahrenheit: useFahrenheit))
            }
        }
        let text = parts.joined(separator: "  ·  ")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let boxWidth = size.width + 16
        let boxHeight = size.height + 10
        var boxX = hoverPoint.x + 14
        if boxX + boxWidth > bounds.maxX - 6 { boxX = hoverPoint.x - boxWidth - 14 }
        boxX = max(bounds.minX + 6, boxX)
        var boxY = hoverPoint.y - boxHeight - 10
        if boxY < bounds.minY + 6 { boxY = hoverPoint.y + 16 }
        boxY = min(boxY, bounds.maxY - boxHeight - 6)
        let box = NSRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)

        let background = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill()
        background.fill()
        NSColor.separatorColor.setStroke()
        background.lineWidth = 0.8
        background.stroke()
        (text as NSString).draw(
            at: NSPoint(x: box.minX + 8, y: box.minY + 5), withAttributes: attributes
        )
    }

    private func xTicks(layout: HistoryChartLayout) -> [Date] {
        let count = 5
        let span = layout.end.timeIntervalSince(layout.start)
        return (0..<count).map { index in
            layout.start.addingTimeInterval(span * Double(index) / Double(count - 1))
        }
    }

    private func dateLabel(_ date: Date, span: TimeInterval) -> String {
        if span <= 2 * 24 * 3600 {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dayFormatter.string(from: date)
    }

    private func scale(for values: [Double]) -> (Double, Double, Double) {
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        if high - low < 0.0001 { high = low + 1 }
        let padding = (high - low) * 0.08
        low -= padding
        high += padding

        let rough = (high - low) / 3
        let step: Double
        if rough <= 0 {
            step = 1
        } else {
            let exponent = floor(log10(rough))
            let fraction = rough / pow(10, exponent)
            let nice: Double
            if fraction <= 1 { nice = 1 }
            else if fraction <= 2 { nice = 2 }
            else if fraction <= 2.5 { nice = 2.5 }
            else if fraction <= 5 { nice = 5 }
            else { nice = 10 }
            step = nice * pow(10, exponent)
        }

        let niceLow = floor(low / step) * step
        let niceHigh = ceil(high / step) * step
        return (niceLow, niceHigh, step)
    }

    private func nearestSample(
        to date: Date, in samples: [HistorySample]
    ) -> HistorySample? {
        guard !samples.isEmpty else { return nil }
        var low = 0
        var high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].date < date { low = mid + 1 } else { high = mid }
        }
        if low > 0,
           abs(samples[low - 1].date.timeIntervalSince(date))
            < abs(samples[low].date.timeIntervalSince(date))
        {
            return samples[low - 1]
        }
        return samples[low]
    }

    private func drawText(
        _ text: String, at point: NSPoint, font: NSFont, color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var x = point.x
        if alignment == .right { x -= size.width }
        if alignment == .center { x -= size.width / 2 }
        (text as NSString).draw(at: NSPoint(x: x, y: point.y), withAttributes: attributes)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let layout = makeLayout(),
              point.x >= layout.plotX, point.x <= layout.plotX + layout.plotWidth
        else {
            clearHover()
            return
        }
        let date = layout.date(atX: point.x)
        guard let sample = nearestSample(to: date, in: layout.samples) else {
            clearHover()
            return
        }
        if hoverDate != sample.date {
            hoverDate = sample.date
            needsDisplay = true
        }
        hoverPoint = point
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let layout = makeLayout() else {
            super.scrollWheel(with: event)
            return
        }
        // Ignore momentum so a flick does not keep moving after the fingers lift.
        guard event.momentumPhase.isEmpty else { return }

        let deltaX = Double(event.scrollingDeltaX)
        let deltaY = Double(event.scrollingDeltaY)

        // Horizontal gestures pan through time; vertical ones zoom. On a
        // diagonal trackpad gesture the dominant axis wins.
        if abs(deltaX) > abs(deltaY) * 1.2, deltaX != 0 {
            pan(by: deltaX, layout: layout, precise: event.hasPreciseScrollingDeltas)
            return
        }

        var delta = deltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        guard delta != 0 else { return }

        // Wheel notches are ±1; trackpad deltas arrive in points. Keep both
        // smooth, and clamp the per-event factor so one accelerated event
        // cannot jump from 17 days to a few hours.
        let steps = event.hasPreciseScrollingDeltas ? Double(delta) / 40.0 : Double(delta)
        let factor = min(max(pow(1.2, steps), 0.8), 1.25)
        zoom(by: factor, at: point)
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard makeLayout() != nil else {
            super.magnify(with: event)
            return
        }
        let factor = 1 + Double(event.magnification)
        guard factor > 0.05 else { return }
        zoom(by: factor, at: point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoom()
        } else {
            super.mouseDown(with: event)
        }
    }

    private func clearHover() {
        guard hoverDate != nil || hoverPoint != nil else { return }
        hoverDate = nil
        hoverPoint = nil
        needsDisplay = true
    }
}

// MARK: - History window

final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onRefresh: (() -> Void)?
    var onTemperatureUnitChanged: ((Bool) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Indoor climate history")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let rangeControl = NSSegmentedControl(
        labels: HistoryRange.allCases.map(\.title),
        trackingMode: .selectOne, target: nil, action: nil
    )
    private let unitButton = NSButton(
        checkboxWithTitle: "Show °F", target: nil, action: nil
    )
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export CSV…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(
        labelWithString: "Scroll ↕ zoom · ↔ pan · double-click reset"
    )
    private let spinner = NSProgressIndicator()
    private let chartView = HistoryChartView()

    private(set) var snapshot: HistorySnapshot?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AranetBar History"
        window.contentMinSize = NSSize(width: 720, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Menu bar apps often have their windows on another Space; bring the
        // history window to whichever Space the user is looking at.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("AranetBarHistoryWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3

        rangeControl.selectedSegment = HistoryRange.all.rawValue
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)
        rangeControl.segmentStyle = .rounded

        unitButton.state = UserDefaults.standard.bool(forKey: "useFahrenheit") ? .on : .off
        unitButton.target = self
        unitButton.action = #selector(unitChanged)

        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        refreshButton.bezelStyle = .rounded

        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.bezelStyle = .rounded

        let toolbarSpacer = NSView()
        toolbarSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbarSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolbarSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true

        let toolbar = NSStackView(
            views: [rangeControl, toolbarSpacer, unitButton, exportButton, refreshButton]
        )
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8

        chartView.useFahrenheit = unitButton.state == .on
        chartView.onZoomStateChanged = { [weak self] zoomed in
            guard let self else { return }
            self.rangeControl.selectedSegment = zoomed
                ? -1
                : self.chartView.range.rawValue
        }
        chartView.setContentHuggingPriority(.defaultLow, for: .vertical)
        chartView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true

        let footer = NSStackView(views: [spinner, statusLabel, footerSpacer, hintLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        for view in [header, toolbar, chartView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            toolbar.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),

            chartView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            chartView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            chartView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            chartView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            chartView.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    }

    func present() {
        // A remembered frame can point at a display that is no longer attached.
        if let window,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) })
        {
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(snapshot: HistorySnapshot?) {
        self.snapshot = snapshot
        chartView.snapshot = snapshot
        guard let snapshot else {
            subtitleLabel.stringValue = "No history downloaded yet"
            return
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = .current
        dayFormatter.timeZone = .current
        dayFormatter.dateFormat = "d MMM"
        var dateText = ""
        if let first = snapshot.samples.first?.date, let last = snapshot.samples.last?.date {
            dateText = "\(dayFormatter.string(from: first)) – \(dayFormatter.string(from: last))"
        }
        let minutes = snapshot.intervalSeconds / 60
        let intervalText = minutes > 0 ? "every \(minutes) min" : "every \(snapshot.intervalSeconds) s"
        var parts = [snapshot.deviceName]
        if !dateText.isEmpty { parts.append(dateText) }
        parts.append("\(snapshot.samples.count.formatted()) readings \(intervalText)")
        if !snapshot.serial.isEmpty { parts.append("SN \(snapshot.serial)") }
        if !snapshot.firmware.isEmpty { parts.append("fw \(snapshot.firmware)") }
        subtitleLabel.stringValue = parts.joined(separator: " · ")
        window?.title = "AranetBar History — \(snapshot.deviceName)"
        chartView.statusMessage = snapshot.samples.isEmpty
            ? "No readings stored on the meter yet"
            : "No history yet"
    }

    func setRange(_ range: HistoryRange) {
        rangeControl.selectedSegment = range.rawValue
        chartView.range = range
    }

    func setTemperatureUnit(_ fahrenheit: Bool) {
        unitButton.state = fahrenheit ? .on : .off
        chartView.useFahrenheit = fahrenheit
    }

    func setLoading(_ loading: Bool, message: String? = nil) {
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        refreshButton.isEnabled = !loading
        exportButton.isEnabled = !loading && snapshot != nil
        if let message {
            statusLabel.stringValue = message
            statusLabel.textColor = .secondaryLabelColor
            if snapshot == nil { chartView.statusMessage = message }
        }
    }

    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemOrange : .secondaryLabelColor
    }

    func prepareForRendering(width: CGFloat = 1_040, height: CGFloat = 820) {
        window?.setContentSize(NSSize(width: width, height: height))
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    func pngData() -> Data? {
        guard let view = window?.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Actions

    @objc private func rangeChanged() {
        chartView.range = HistoryRange(rawValue: rangeControl.selectedSegment) ?? .all
    }

    @objc private func unitChanged() {
        let fahrenheit = unitButton.state == .on
        chartView.useFahrenheit = fahrenheit
        UserDefaults.standard.set(fahrenheit, forKey: "useFahrenheit")
        onTemperatureUnitChanged?(fahrenheit)
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func exportTapped() {
        guard let snapshot, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "aranet-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try HistoryCSV.write(snapshot, to: url)
                self?.setStatus(
                    "Wrote \(snapshot.samples.count.formatted()) readings to \(url.lastPathComponent)",
                    isError: false
                )
            } catch {
                self?.setStatus("Could not write CSV: \(error.localizedDescription)", isError: true)
                let alert = NSAlert()
                alert.messageText = "Could not write the CSV"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

// MARK: - App

final class AranetBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate, CBCentralManagerDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var central: CBCentralManager?
    private var reading: AranetReading?
    private var deviceName: String?
    private var peripheral: CBPeripheral?
    private var verbose = false
    private var oneshot = false
    private var dumpMenu = false
    private var lastLoggedSignature: String?

    // History window and its on-demand GATT session.
    private var historyController: HistoryWindowController?
    private var historyDownloader: HistoryDownloader?
    private var cachedHistory: HistorySnapshot?
    private var pendingHistoryRefresh = false
    private var headlessHistory = false
    private var historyStarted = false
    private var historyDays: Double?
    private var historyCSVPath: String?
    private var historyJSONPath: String?
    private var historyRenderPath: String?
    private var historyRenderRange: HistoryRange?
    private var showHistoryOnLaunch = false

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
        headlessHistory = args.contains("--history")
        showHistoryOnLaunch = args.contains("--show-history")
        historyCSVPath = argumentValue("--history-csv", in: args)
        historyJSONPath = argumentValue("--history-json", in: args)
        historyRenderPath = argumentValue("--render-history", in: args)
        historyRenderRange = argumentValue("--history-range", in: args).flatMap { value in
            switch value.lowercased() {
            case "day", "24h", "24": return .day
            case "week", "7d", "7": return .week
            default: return .all
            }
        }
        historyDays = argumentValue("--history-days", in: args).flatMap(Double.init)
        cachedHistory = HistoryStore.load()

        log("🚀 aranetbar starting")

        // A cache-only render is handy for docs and for checking the chart
        // without waking the meter.
        if let path = historyRenderPath, !headlessHistory {
            guard let snapshot = cachedHistory else {
                FileHandle.standardError.write(Data("No cached history to render.\n".utf8))
                exit(1)
            }
            renderHistory(snapshot, to: path)
            exit(0)
        }

        if !oneshot, !dumpMenu, !headlessHistory {
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
        } else if headlessHistory {
            onceTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { _ in
                FileHandle.standardError.write(
                    Data("No Aranet4 advertisement seen, or the history download did not start.\n".utf8)
                )
                exit(1)
            }
        } else {
            // Re-render periodically so staleness is reflected in the title.
            ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.updateTitle()
            }
            if showHistoryOnLaunch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.showHistory()
                }
            }
        }
    }

    private func argumentValue(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
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
            } else if headlessHistory {
                startScanCycle()
            } else {
                startScanCycle()
            }
        case .unauthorized:
            log("❌ Bluetooth permission denied")
            historyDownloader?.cancel()
            historyDownloader = nil
            if !oneshot, !headlessHistory { showError("Bluetooth permission denied") }
            if headlessHistory { exit(1) }
        case .poweredOff:
            historyDownloader?.cancel()
            historyDownloader = nil
            if !oneshot, !headlessHistory { showError("Bluetooth is off") }
            if headlessHistory { exit(1) }
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
        self.peripheral = peripheral

        let previous = reading
        reading = parsed

        if headlessHistory, !historyStarted, historyDownloader == nil {
            historyStarted = true
            beginHistoryDownload()
            return
        }

        if pendingHistoryRefresh, historyDownloader == nil {
            pendingHistoryRefresh = false
            beginHistoryDownload()
        }

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

    // These central callbacks belong to the history session. The live menu bar
    // never connects, so there is only ever one possible downloader.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let downloader = historyDownloader,
              downloader.peripheral.identifier == peripheral.identifier
        else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        downloader.didConnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard historyDownloader?.peripheral.identifier == peripheral.identifier else { return }
        historyDownloader?.didFailToConnect(error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard historyDownloader?.peripheral.identifier == peripheral.identifier else { return }
        historyDownloader?.didDisconnect(error)
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
        guard historyDownloader == nil else { return }
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

    // MARK: History

    private func historyWindow() -> HistoryWindowController {
        if let historyController { return historyController }
        let controller = HistoryWindowController()
        controller.update(snapshot: cachedHistory)
        controller.onRefresh = { [weak self] in self?.refreshHistory() }
        controller.onTemperatureUnitChanged = { [weak self] fahrenheit in
            self?.log("🌡 fahrenheit = \(fahrenheit)")
        }
        historyController = controller
        return controller
    }

    @objc private func showHistory() {
        let controller = historyWindow()
        controller.present()

        if let cached = cachedHistory {
            if Date().timeIntervalSince(cached.downloadedAt) <= 120 {
                controller.setStatus(
                    "Updated \(Self.relativeTime(cached.downloadedAt)) · "
                        + "\(cached.samples.count.formatted()) readings",
                    isError: false
                )
                return
            }
        }
        refreshHistory()
    }

    private func refreshHistory() {
        guard historyDownloader == nil else { return }
        guard let central else { return }
        guard central.state == .poweredOn else {
            if central.state == .unknown || central.state == .resetting {
                pendingHistoryRefresh = true
                historyController?.setLoading(true, message: "Waiting for Bluetooth…")
            } else {
                historyController?.setLoading(false)
                historyController?.setStatus("Bluetooth is off.", isError: true)
            }
            return
        }
        guard peripheral != nil else {
            pendingHistoryRefresh = true
            historyController?.setLoading(true, message: "Looking for your Aranet4…")
            beginScan()
            return
        }
        pendingHistoryRefresh = false
        beginHistoryDownload()
    }

    private func beginHistoryDownload() {
        guard historyDownloader == nil,
              let peripheral,
              let central,
              central.state == .poweredOn
        else { return }

        endScan()
        historyController?.setLoading(
            true, message: "Connecting to \(deviceName ?? "the meter")…"
        )
        let downloader = HistoryDownloader(
            peripheral: peripheral,
            central: central,
            days: historyDays,
            delegate: self
        )
        historyDownloader = downloader
        downloader.start()
    }

    private func handleHistoryResult(_ result: Result<HistorySnapshot, Error>) {
        historyDownloader = nil
        onceTimeout?.invalidate()

        switch result {
        case .success(let snapshot):
            cachedHistory = snapshot
            if historyDays == nil {
                HistoryStore.save(snapshot)
            }

            historyController?.update(snapshot: snapshot)
            historyController?.setLoading(false)
            let warningSuffix = snapshot.warnings.isEmpty
                ? ""
                : " · \(snapshot.warnings.count) series incomplete"
            historyController?.setStatus(
                "Updated \(Self.relativeTime(snapshot.downloadedAt)) · "
                    + "\(snapshot.samples.count.formatted()) readings\(warningSuffix)",
                isError: !snapshot.warnings.isEmpty
            )

            if headlessHistory {
                let problems = writeHistoryOutputs(snapshot)
                printHistorySummary(snapshot)
                for problem in problems {
                    FileHandle.standardError.write(Data("\(problem)\n".utf8))
                }
                if let path = historyRenderPath {
                    renderHistory(snapshot, to: path)
                }
                exit(problems.isEmpty ? 0 : 1)
            }
            beginScan()

        case .failure(let error):
            historyController?.setLoading(false)
            historyController?.setStatus(error.localizedDescription, isError: true)

            if headlessHistory {
                FileHandle.standardError.write(
                    Data("History download failed: \(error.localizedDescription)\n".utf8)
                )
                exit(1)
            }
            beginScan()
        }
    }

    private func writeHistoryOutputs(_ snapshot: HistorySnapshot) -> [String] {
        var problems: [String] = []
        if let path = historyJSONPath {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                try encoder.encode(snapshot).write(to: url, options: .atomic)
                print("Wrote \(snapshot.samples.count) readings to \(url.path)")
            } catch {
                problems.append("Could not write JSON: \(error.localizedDescription)")
            }
        }
        if let path = historyCSVPath {
            do {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                try HistoryCSV.write(snapshot, to: url)
                print("Wrote \(snapshot.samples.count) readings to \(url.path)")
            } catch {
                problems.append("Could not write CSV: \(error.localizedDescription)")
            }
        }
        return problems
    }

    private func printHistorySummary(_ snapshot: HistorySnapshot) {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "d MMM yyyy HH:mm"

        var header = snapshot.deviceName
        if !snapshot.serial.isEmpty { header += " · SN \(snapshot.serial)" }
        if !snapshot.firmware.isEmpty { header += " · fw \(snapshot.firmware)" }
        print(header)
        if let first = snapshot.samples.first?.date, let last = snapshot.samples.last?.date {
            print(
                "\(snapshot.samples.count) records · "
                    + "\(dateFormatter.string(from: first)) – \(dateFormatter.string(from: last))"
                    + " · every \(snapshot.intervalSeconds) s"
            )
        }
        let co2 = snapshot.samples.compactMap(\.co2)
        if let low = co2.min(), let high = co2.max() {
            let average = co2.reduce(0, +) / max(co2.count, 1)
            print("CO₂ \(low)–\(high) ppm (avg \(average))")
        }
        let temperatures = snapshot.samples.compactMap(\.temperatureC)
        if let low = temperatures.min(), let high = temperatures.max() {
            print(String(format: "Temperature %.2f–%.2f °C", low, high))
        }
        let humidity = snapshot.samples.compactMap(\.humidity)
        if let low = humidity.min(), let high = humidity.max() {
            print("Humidity \(low)–\(high) %")
        }
        let pressure = snapshot.samples.compactMap(\.pressureHpa)
        if let low = pressure.min(), let high = pressure.max() {
            print(String(format: "Pressure %.1f–%.1f hPa", low, high))
        }
        for warning in snapshot.warnings {
            print("⚠️  \(warning)")
        }
    }

    private func renderHistory(_ snapshot: HistorySnapshot, to path: String) {
        let controller = HistoryWindowController()
        controller.update(snapshot: snapshot)
        if let historyRenderRange { controller.setRange(historyRenderRange) }
        controller.setLoading(false)
        controller.setStatus(
            "Updated \(Self.relativeTime(snapshot.downloadedAt)) · "
                + "\(snapshot.samples.count.formatted()) readings",
            isError: false
        )
        controller.prepareForRendering()
        guard let data = controller.pngData() else {
            FileHandle.standardError.write(Data("Could not render the history window.\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try data.write(to: url, options: .atomic)
            print("Rendered \(url.path)")
        } catch {
            FileHandle.standardError.write(
                Data("Could not write the chart: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 10 { return "just now" }
        if seconds < 90 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 90 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 36 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
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

        let history = NSMenuItem(
            title: "History…", action: #selector(showHistory), keyEquivalent: "h"
        )
        history.target = self
        menu.addItem(history)

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
        historyController?.setTemperatureUnit(useFahrenheit)
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

extension AranetBarApp: HistoryDownloaderDelegate {
    func historyDownloader(_ downloader: HistoryDownloader, didProgress message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.historyController?.setLoading(
                true, message: "Downloading history · \(message)…"
            )
        }
    }

    func historyDownloader(
        _ downloader: HistoryDownloader,
        didFinish result: Result<HistorySnapshot, Error>
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.handleHistoryResult(result)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        historyDownloader?.cancel()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AranetBarApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
