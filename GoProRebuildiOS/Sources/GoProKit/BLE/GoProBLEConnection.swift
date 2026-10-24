import CoreBluetooth
import Foundation

/// GATT client for one GoPro camera.
///
/// Port of `ble/GoProBleConnection.kt`. Writes use `.withResponse`, matching the
/// Android Kable implementation. Responses arrive as notifications on the
/// response characteristics and are reassembled by `GoProFrameAccumulator`.
@MainActor
public final class GoProBLEConnection: NSObject, ObservableObject {
    @Published public private(set) var connectionState: BLEConnectionState = .disconnected
    @Published public private(set) var statusMap: [Int: Int] = [:]
    @Published public private(set) var settingsMap: [Int: Int] = [:]

    private let central: GoProBluetoothCentral
    private let device: GoProDevice

    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var settingCharacteristic: CBCharacteristic?
    private var queryCharacteristic: CBCharacteristic?
    private var wifiSSIDCharacteristic: CBCharacteristic?
    private var wifiPasswordCharacteristic: CBCharacteristic?
    private var wifiSwitchCharacteristic: CBCharacteristic?

    private let queryAccumulator = GoProFrameAccumulator()
    private let settingAccumulator = GoProFrameAccumulator()

    private var serviceDiscoveryContinuation: CheckedContinuation<Void, Error>?
    private var pendingServiceDiscoveries = 0
    private var commandResponseWaiter: CommandResponseWaiter?
    private var readWaiters: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    /// Characteristics that GoPro firmware only pushes over notifications.
    private static let notificationCharacteristicUUIDs: Set<CBUUID> = [
        GoProBLE.charCommandResponse,
        GoProBLE.charSettingResponse,
        GoProBLE.charQueryResponse,
    ]

    public init(central: GoProBluetoothCentral, device: GoProDevice) {
        self.central = central
        self.device = device
        super.init()
        central.peripheralDelegate = self
    }

    // MARK: - Connect / disconnect

    public func connect() async throws {
        connectionState = .connecting
        do {
            guard let peripheral = central.peripheral(for: device.identifier) else {
                throw GoProError.bluetoothUnavailable("Unknown peripheral \(device.identifier)")
            }
            self.peripheral = peripheral
            peripheral.delegate = self

            try await central.connect(peripheral)
            try await discoverServices()

            // Settle delay: GoPro firmware is not always ready to accept writes
            // the moment characteristics are discovered.
            try await Task.sleep(nanoseconds: 500_000_000)

            try await queryAllStatus()
            try await queryAllSettings()

            connectionState = .connected
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async {
        if let peripheral {
            central.disconnect(peripheral)
        }
        connectionState = .disconnected
    }

    private func discoverServices() async throws {
        guard let peripheral else { throw GoProError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            serviceDiscoveryContinuation = continuation
            peripheral.discoverServices(GoProBLE.servicesOfInterest)
        }
    }

    // MARK: - Commands

    /// Send a raw command and wait up to 3s for its notification response.
    @discardableResult
    public func sendCommand(_ command: [UInt8]) async throws -> Data? {
        guard let commandCharacteristic else { throw GoProError.notConnected }
        try await write(Data(command), to: commandCharacteristic)
        return await waitForCommandResponse(timeout: 3)
    }

    /// Resolve with the next command response, or `nil` when the camera stays silent.
    private func waitForCommandResponse(timeout: Double) async -> Data? {
        let waiter = CommandResponseWaiter()
        commandResponseWaiter = waiter

        let timeoutTask = Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            waiter?.resolve(nil)
        }
        defer { timeoutTask.cancel() }

        return await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            // The response may have arrived before the continuation was stored.
            waiter.flush()
        }
    }

    public func shutterOn() async throws { try await sendCommand(GoProCommands.shutterOn) }
    public func shutterOff() async throws { try await sendCommand(GoProCommands.shutterOff) }
    public func powerOff() async throws { try await sendCommand(GoProCommands.powerOff) }
    public func keepAlive() async throws { try await sendCommand(GoProCommands.keepAlive) }
    public func enableWifi() async throws { try await sendCommand(GoProCommands.wifiApOn) }
    public func disableWifi() async throws { try await sendCommand(GoProCommands.wifiApOff) }
    public func setModeVideo() async throws { try await sendCommand(GoProCommands.modeVideo) }
    public func setModePhoto() async throws { try await sendCommand(GoProCommands.modePhoto) }
    public func setModeTimelapse() async throws { try await sendCommand(GoProCommands.modeTimelapse) }

    /// Send a set-setting command over the setting characteristic.
    public func setSetting(settingId: Int, value: Int) async throws {
        guard let settingCharacteristic else { throw GoProError.notConnected }
        try await write(
            Data(GoProCommands.setSetting(settingId: settingId, value: value)),
            to: settingCharacteristic
        )
        settingsMap[settingId] = value
    }

    // MARK: - Queries

    public func queryAllStatus() async throws {
        guard let queryCharacteristic else { throw GoProError.notConnected }
        try await write(Data(GoProCommands.queryAllStatus), to: queryCharacteristic)
        try await write(Data(GoProCommands.registerStatusUpdates), to: queryCharacteristic)
    }

    public func queryAllSettings() async throws {
        guard let queryCharacteristic else { throw GoProError.notConnected }
        try await write(Data(GoProCommands.queryAllSettings), to: queryCharacteristic)
        try await write(Data(GoProCommands.registerSettingsUpdates), to: queryCharacteristic)
    }

    // MARK: - WiFi credentials

    /// Read the camera hotspot SSID and password from the WiFi AP service.
    public func getWifiCredentials() async throws -> WifiCredentials {
        let ssidData = try await read(characteristic: wifiSSIDCharacteristic)
        let passwordData = try await read(characteristic: wifiPasswordCharacteristic)
        let ssid = String(data: ssidData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = String(data: passwordData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ssid.isEmpty, !password.isEmpty else { throw GoProError.wifiCredentialsUnavailable }
        return WifiCredentials(ssid: ssid, password: password)
    }

    /// Turn the camera WiFi AP on over BLE.
    public func enableWifiAp() async throws {
        guard let wifiSwitchCharacteristic else { throw GoProError.notConnected }
        try await write(Data([0x01]), to: wifiSwitchCharacteristic)
    }

    // MARK: - Camera info

    /// Read model, firmware and serial from the Device Information service.
    /// Older cameras do not expose it; whatever is readable is returned.
    public func getCameraInfo() async -> CameraInfo {
        var model = device.name
        var firmware = "Unknown"
        var serial = "Unknown"

        if let data = try? await read(uuid: GoProBLE.charModelNumber),
           let text = Self.utf8String(data), !text.isEmpty {
            model = GoProModel.displayName(raw: text, fallback: device.name)
        }
        if let data = try? await read(uuid: GoProBLE.charFirmwareRevision),
           let text = Self.utf8String(data), !text.isEmpty {
            firmware = text
        }
        if let data = try? await read(uuid: GoProBLE.charSerialNumber),
           let text = Self.utf8String(data), !text.isEmpty {
            serial = text
        }

        return CameraInfo(model: model, firmware: firmware, serialNumber: serial)
    }

    // MARK: - Read / write helpers

    private func read(uuid: CBUUID) async throws -> Data {
        guard let characteristic = characteristic(withUUID: uuid) else {
            throw GoProError.notConnected
        }
        return try await read(characteristic: characteristic)
    }

    private func read(characteristic: CBCharacteristic?) async throws -> Data {
        guard let peripheral, let characteristic else { throw GoProError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            readWaiters[characteristic.uuid] = continuation
            peripheral.readValue(for: characteristic)
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic) async throws {
        guard let peripheral else { throw GoProError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeWaiters[characteristic.uuid] = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func characteristic(withUUID uuid: CBUUID) -> CBCharacteristic? {
        for service in peripheral?.services ?? [] {
            if let match = service.characteristics?.first(where: { $0.uuid == uuid }) {
                return match
            }
        }
        return nil
    }

    private static func utf8String(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response parsing

    private func handleQueryResponse(_ data: Data) {
        guard let fullFrame = queryAccumulator.feed(data),
              let update = GoProTLVParser.parseQueryResponse(fullFrame) else { return }
        if !update.statuses.isEmpty {
            statusMap.merge(update.statuses) { _, new in new }
        }
        if !update.settings.isEmpty {
            settingsMap.merge(update.settings) { _, new in new }
        }
    }

    private func handleSettingResponse(_ data: Data) {
        guard let fullFrame = settingAccumulator.feed(data) else { return }
        settingsMap.merge(GoProTLVParser.parseSettingResponse(fullFrame)) { _, new in new }
    }
}

// MARK: - Command response waiter

/// Single-flight waiter for one command response.
///
/// A notification can arrive between the write and the continuation being
/// stored, so the value is buffered and flushed by `sendCommand`.
@MainActor
final class CommandResponseWaiter {
    var continuation: CheckedContinuation<Data?, Never>?
    private var pendingValue: Data??

    func resolve(_ value: Data?) {
        guard let continuation else {
            pendingValue = .some(value)
            return
        }
        self.continuation = nil
        continuation.resume(returning: value)
    }

    func flush() {
        guard let value = pendingValue, let continuation else { return }
        pendingValue = nil
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

// MARK: - CBPeripheralDelegate

extension GoProBLEConnection: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard serviceDiscoveryContinuation != nil else { return }

        if let error {
            finishServiceDiscovery(.failure(error))
            return
        }

        let targets = (peripheral.services ?? []).filter {
            GoProBLE.servicesOfInterest.contains($0.uuid)
        }

        guard !targets.isEmpty else {
            finishServiceDiscovery(.success(()))
            return
        }

        pendingServiceDiscoveries = targets.count
        for service in targets {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case GoProBLE.charCommand:
                commandCharacteristic = characteristic
            case GoProBLE.charSetting:
                settingCharacteristic = characteristic
            case GoProBLE.charQuery:
                queryCharacteristic = characteristic
            case GoProBLE.charWifiSSID:
                wifiSSIDCharacteristic = characteristic
            case GoProBLE.charWifiPassword:
                wifiPasswordCharacteristic = characteristic
            case GoProBLE.charWifiSwitch:
                wifiSwitchCharacteristic = characteristic
            default:
                if Self.notificationCharacteristicUUIDs.contains(characteristic.uuid) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }

        if serviceDiscoveryContinuation != nil {
            pendingServiceDiscoveries -= 1
            if pendingServiceDiscoveries <= 0 {
                finishServiceDiscovery(.success(()))
            }
        }
    }

    private func finishServiceDiscovery(_ result: Result<Void, Error>) {
        guard let continuation = serviceDiscoveryContinuation else { return }
        serviceDiscoveryContinuation = nil
        continuation.resume(with: result)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let value = characteristic.value ?? Data()

        if let waiter = readWaiters.removeValue(forKey: characteristic.uuid) {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: value)
            }
            return
        }

        guard error == nil else { return }

        switch characteristic.uuid {
        case GoProBLE.charCommandResponse:
            commandResponseWaiter?.resolve(value)
            commandResponseWaiter = nil
        case GoProBLE.charQueryResponse:
            handleQueryResponse(value)
        case GoProBLE.charSettingResponse:
            handleSettingResponse(value)
        default:
            break
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let waiter = writeWaiters.removeValue(forKey: characteristic.uuid) else { return }
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }
}
