import CoreBluetooth

/// GoPro BLE service and characteristic UUIDs.
/// Values match the Android implementation in
/// `app/src/main/java/com/gopro/rebuild/ble/GoProBleConstants.kt`.
public enum GoProBLE {
    // MARK: Services

    /// Control Point service, main command interface.
    public static let serviceControlPoint = CBUUID(string: "0000FEA6-0000-1000-8000-00805F9B34FB")
    /// WiFi Access Point service, holds the camera hotspot credentials.
    public static let serviceWifiAP = CBUUID(string: "B5F90001-AA8D-11E3-9046-0002A5D5C51B")
    /// Camera management service.
    public static let serviceCameraMgmt = CBUUID(string: "B5F90090-AA8D-11E3-9046-0002A5D5C51B")
    /// Standard Device Information service.
    public static let serviceDeviceInfo = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")

    public static let servicesOfInterest: [CBUUID] = [
        serviceControlPoint,
        serviceWifiAP,
        serviceCameraMgmt,
        serviceDeviceInfo,
    ]

    // MARK: Control Point characteristics

    public static let charCommand = CBUUID(string: "B5F90072-AA8D-11E3-9046-0002A5D5C51B")
    public static let charCommandResponse = CBUUID(string: "B5F90073-AA8D-11E3-9046-0002A5D5C51B")
    public static let charSetting = CBUUID(string: "B5F90074-AA8D-11E3-9046-0002A5D5C51B")
    public static let charSettingResponse = CBUUID(string: "B5F90075-AA8D-11E3-9046-0002A5D5C51B")
    public static let charQuery = CBUUID(string: "B5F90076-AA8D-11E3-9046-0002A5D5C51B")
    public static let charQueryResponse = CBUUID(string: "B5F90077-AA8D-11E3-9046-0002A5D5C51B")

    // MARK: WiFi AP characteristics

    public static let charWifiSSID = CBUUID(string: "B5F90002-AA8D-11E3-9046-0002A5D5C51B")
    public static let charWifiPassword = CBUUID(string: "B5F90003-AA8D-11E3-9046-0002A5D5C51B")
    public static let charWifiSwitch = CBUUID(string: "B5F90004-AA8D-11E3-9046-0002A5D5C51B")
    public static let charWifiState = CBUUID(string: "B5F90005-AA8D-11E3-9046-0002A5D5C51B")

    // MARK: Camera management characteristics

    public static let charMgmtCommand = CBUUID(string: "B5F90091-AA8D-11E3-9046-0002A5D5C51B")
    public static let charMgmtResponse = CBUUID(string: "B5F90092-AA8D-11E3-9046-0002A5D5C51B")

    // MARK: Device Information characteristics

    public static let charManufacturer = CBUUID(string: "00002A29-0000-1000-8000-00805F9B34FB")
    public static let charModelNumber = CBUUID(string: "00002A24-0000-1000-8000-00805F9B34FB")
    public static let charSerialNumber = CBUUID(string: "00002A25-0000-1000-8000-00805F9B34FB")
    public static let charFirmwareRevision = CBUUID(string: "00002A26-0000-1000-8000-00805F9B34FB")
    public static let charHardwareRevision = CBUUID(string: "00002A27-0000-1000-8000-00805F9B34FB")
}
