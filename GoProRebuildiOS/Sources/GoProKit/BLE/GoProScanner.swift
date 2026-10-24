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
        let peripheralName = peripheral.name

        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasGoProService = advertisedServices.contains {
            $0 == GoProBLE.serviceControlPoint
                || $0 == GoProBLE.serviceWifiAP
                || $0 == GoProBLE.serviceCameraMgmt
        }

        // Check GoPro manufacturer data (Company ID 0x02F2 = 754)
        var hasGoProMfg = false
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 2 {
            let companyId = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
            if companyId == 0x02F2 {
                hasGoProMfg = true
            }
        }

        let rawName = advertisedName ?? peripheralName
        let isStrictName = rawName.map { GoProDevice.looksLikeGoPro($0) } ?? false

        guard hasGoProMfg || hasGoProService || isStrictName else { return }

        let finalName = rawName ?? "GoPro Camera"

        let device = GoProDevice(
            identifier: peripheral.identifier,
            name: finalName,
            rssi: rssi,
            isPaired: false
        )

        if let index = devices.firstIndex(where: { $0.identifier == device.identifier || $0.name == device.name }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }
}
