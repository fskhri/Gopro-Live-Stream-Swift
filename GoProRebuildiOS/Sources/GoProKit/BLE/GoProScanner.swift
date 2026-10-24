import CoreBluetooth
import Foundation

/// Discovers GoPro cameras over BLE.
///
/// Port of `ble/GoProScanner.kt`. Android could list bonded devices and read MAC
/// addresses; iOS exposes neither, so discovery is scan-only and devices are
/// identified by `CBPeripheral.identifier`.
@MainActor
public final class GoProScanner: NSObject, ObservableObject {
    @Published public private(set) var devices: [GoProDevice] = []
    @Published public private(set) var isScanning = false

    private let central: GoProBluetoothCentral

    public init(central: GoProBluetoothCentral) {
        self.central = central
        super.init()
        central.onDiscover = { [weak self] peripheral, advertisementData, rssi in
            self?.handleDiscovery(peripheral, advertisementData: advertisementData, rssi: rssi)
        }
    }

    public func startScan() async throws {
        try await central.waitUntilReady()
        devices.removeAll()
        isScanning = true
        // No service filter: some firmware advertises the GoPro services only in
        // the scan response, and filtering on them hides those cameras.
        central.startScan(withServices: nil, allowDuplicates: false)
    }

    public func stopScan() {
        central.stopScan()
        isScanning = false
    }

    public func clear() {
        devices.removeAll()
    }

    /// Live peripheral object for a discovered camera.
    public func peripheral(for device: GoProDevice) -> CBPeripheral? {
        central.peripheral(for: device.identifier)
    }

    private func handleDiscovery(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: Int) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name ?? "HERO Camera"

        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasGoProService = advertisedServices.contains {
            $0 == GoProBLE.serviceControlPoint
                || $0 == GoProBLE.serviceWifiAP
                || $0 == GoProBLE.serviceCameraMgmt
        }

        guard GoProDevice.looksLikeGoPro(name) || hasGoProService else { return }

        let device = GoProDevice(
            identifier: peripheral.identifier,
            name: name,
            rssi: rssi,
            isPaired: false
        )

        if let index = devices.firstIndex(where: { $0.identifier == device.identifier }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }
}
