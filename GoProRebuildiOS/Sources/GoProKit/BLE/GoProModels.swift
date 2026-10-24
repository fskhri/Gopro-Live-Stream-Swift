import CoreBluetooth
import Foundation

/// A GoPro camera seen over BLE.
///
/// iOS has no MAC address access; `identifier` is the system-assigned
/// `CBPeripheral.identifier`, stable per device on a given phone.
public struct GoProDevice: Identifiable, Hashable, Sendable {
    public var id: UUID { identifier }
    /// Stable CoreBluetooth identifier for this camera.
    public let identifier: UUID
    /// Advertised name, e.g. "GoPro 1470" or "HERO6 Black".
    public let name: String
    /// Last advertised RSSI.
    public let rssi: Int
    /// Whether iOS knows this peripheral from a previous pairing.
    public let isPaired: Bool

    public init(identifier: UUID, name: String, rssi: Int = 0, isPaired: Bool = false) {
        self.identifier = identifier
        self.name = name
        self.rssi = rssi
        self.isPaired = isPaired
    }

    /// Match the same name heuristics the Android scanner used, tightened to
    /// avoid false positives from other Bluetooth devices whose names happen
    /// to start with a short prefix like "GP".
    public static func looksLikeGoPro(_ name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let lowered = name.lowercased()
        // Exact or "GoPro XXXX" style
        if lowered.hasPrefix("gopro") { return true }
        // Model names: HERO, HERO6, HERO6 Black, etc.
        if lowered.hasPrefix("hero") { return true }
        // Older: HD HERO, HD2, HD3
        if lowered.hasPrefix("hd") && (lowered.contains("hero") || lowered.contains("gopro")) { return true }
        // 360 cameras
        if lowered.hasPrefix("fusion") || lowered.hasPrefix("max") { return true }
        // "GoPro 1470" pattern: "GP" followed by digits/space
        if lowered.hasPrefix("gp") {
            let suffix = name.dropFirst(2)
            // Must be "GP XXXX" or "GPXXXX" where X is digit or space
            if suffix.isEmpty { return false }
            let first = suffix.first!
            return first.isNumber || first == " "
        }
        return false
    }
}

/// WiFi credentials read from the camera's WiFi AP service.
public struct WifiCredentials: Equatable, Sendable {
    public let ssid: String
    public let password: String

    public init(ssid: String, password: String) {
        self.ssid = ssid
        self.password = password
    }
}

/// Hardware info read from the Device Information service.
public struct CameraInfo: Equatable, Sendable {
    public let model: String
    public let firmware: String
    public let serialNumber: String

    public init(model: String, firmware: String, serialNumber: String) {
        self.model = model
        self.firmware = firmware
        self.serialNumber = serialNumber
    }
}

/// BLE link state.
public enum BLEConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// Camera WiFi AP link state.
public enum WifiConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// Errors thrown by GoProKit layers.
public enum GoProError: Error, Equatable {
    case bluetoothUnavailable(String)
    case notConnected
    case timeout
    case cameraUnreachable
    case wifiJoinFailed(String)
    case wifiCredentialsUnavailable
    case invalidResponse(Int)
    case decodingFailed(String)
}

extension GoProError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let reason):
            return "Bluetooth unavailable: \(reason)"
        case .notConnected:
            return "Camera is not connected"
        case .timeout:
            return "The camera did not answer in time"
        case .cameraUnreachable:
            return "The camera is not reachable on WiFi"
        case .wifiJoinFailed(let reason):
            return "Could not join the camera hotspot: \(reason)"
        case .wifiCredentialsUnavailable:
            return "The camera did not share its WiFi credentials"
        case .invalidResponse(let code):
            return "The camera answered with HTTP \(code)"
        case .decodingFailed(let reason):
            return "Could not read the camera response: \(reason)"
        }
    }
}
