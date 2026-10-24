import CoreBluetooth
import Foundation

/// Owns the single `CBCentralManager` for the app.
///
/// Holds scanning and connection state, and forwards peripheral events to the
/// handlers registered by `GoProScanner` and `GoProBLEConnection`. The central
/// manager is created on the main queue, so every delegate callback arrives on
/// the main thread and can touch main-actor state directly.
@MainActor
public final class GoProBluetoothCentral: NSObject, ObservableObject {
    public enum State: Equatable {
        case unknown
        case unsupported
        case unauthorized
        case poweredOff
        case poweredOn
        case resetting
    }

    @Published public private(set) var state: State = .unknown

    /// Peripherals discovered by the current scan, keyed by identifier.
    public private(set) var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    public var onDiscover: ((CBPeripheral, [String: Any], Int) -> Void)?
    public var onConnect: ((CBPeripheral) -> Void)?
    public var onDisconnect: ((CBPeripheral, Error?) -> Void)?
    public var onFailToConnect: ((CBPeripheral, Error?) -> Void)?

    /// Peripheral-level delegate for the connected camera, set by `GoProBLEConnection`.
    public weak var peripheralDelegate: CBPeripheralDelegate?

    private var manager: CBCentralManager?
    private var connectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var connectTimeouts: [UUID: Task<Void, Never>] = [:]

    public override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    public var isReady: Bool { state == .poweredOn }

    /// Wait until the central manager reports a usable state.
    public func waitUntilReady(timeout: Double = 5) async throws {
        if isReady { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .unsupported || state == .unauthorized {
                throw GoProError.bluetoothUnavailable("Bluetooth \(state == .unsupported ? "unsupported" : "permission denied")")
            }
            if isReady { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw GoProError.bluetoothUnavailable("Bluetooth did not become ready")
    }

    public func startScan(withServices services: [CBUUID]? = nil, allowDuplicates: Bool = false) {
        guard let manager else { return }
        discoveredPeripherals.removeAll()
        manager.scanForPeripherals(
            withServices: services,
            options: allowDuplicates ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil
        )
    }

    public func stopScan() {
        manager?.stopScan()
    }

    /// Get the live peripheral object for a known identifier.
    public func peripheral(for identifier: UUID) -> CBPeripheral? {
        if let live = discoveredPeripherals[identifier] {
            return live
        }
        guard let known = manager?.retrievePeripherals(withIdentifiers: [identifier]).first else {
            return nil
        }
        discoveredPeripherals[identifier] = known
        return known
    }

    /// Connect to a peripheral and wait until the link is up.
    /// A timeout is required: CoreBluetooth can stay silent for a camera that
    /// never answers.
    public func connect(_ peripheral: CBPeripheral, timeout: Double = 12) async throws {
        guard let manager else { throw GoProError.bluetoothUnavailable("No central manager") }
        guard state == .poweredOn else {
            throw GoProError.bluetoothUnavailable("Bluetooth is \(state)")
        }
        guard peripheral.state != .connected else { return }

        discoveredPeripherals[peripheral.identifier] = peripheral

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiters[peripheral.identifier] = continuation
            manager.connect(peripheral, options: nil)
            connectTimeouts[peripheral.identifier] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                self.timeoutConnect(peripheral.identifier)
            }
        }
    }

    public func disconnect(_ peripheral: CBPeripheral) {
        manager?.cancelPeripheralConnection(peripheral)
    }

    private func timeoutConnect(_ identifier: UUID) {
        guard let waiter = connectWaiters.removeValue(forKey: identifier) else { return }
        connectTimeouts[identifier] = nil
        if let peripheral = discoveredPeripherals[identifier] {
            manager?.cancelPeripheralConnection(peripheral)
        }
        waiter.resume(throwing: GoProError.timeout)
    }

    private func finishConnect(_ identifier: UUID, result: Result<Void, Error>) {
        connectTimeouts.removeValue(forKey: identifier)?.cancel()
        guard let waiter = connectWaiters.removeValue(forKey: identifier) else { return }
        waiter.resume(with: result)
    }
}

extension GoProBluetoothCentral: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = .poweredOn
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        case .resetting: state = .resetting
        default: state = .unknown
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        onDiscover?(peripheral, advertisementData, RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = peripheralDelegate
        discoveredPeripherals[peripheral.identifier] = peripheral
        finishConnect(peripheral.identifier, result: .success(()))
        onConnect?(peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        finishConnect(
            peripheral.identifier,
            result: .failure(error ?? GoProError.bluetoothUnavailable("Failed to connect"))
        )
        onFailToConnect?(peripheral, error)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        onDisconnect?(peripheral, error)
    }
}
