import Foundation
#if os(iOS)
import NetworkExtension
#endif

/// Joins and monitors the camera WiFi hotspot.
///
/// Replaces `wifi/WifiConnectionManager.kt`. Android could create the network,
/// bind the process to it, and read the active network's routes. iOS offers
/// neither: `NEHotspotConfiguration` joins the hotspot, and the system routes
/// local traffic to it, so reachability is decided by probing the camera HTTP
/// endpoint instead of inspecting routes.
@MainActor
public final class WifiConnectionManager: ObservableObject {
    @Published public private(set) var connectionState: WifiConnectionState = .disconnected
    @Published public private(set) var currentSSID: String?

    /// Camera host on its own hotspot. Fixed by GoPro firmware.
    public static let cameraHost = "10.5.5.9"

    private let probeSession: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        probeSession = URLSession(configuration: configuration)
    }

    /// Join the camera hotspot. On success the system keeps using this network,
    /// even though it has no internet access.
    public func join(ssid: String, password: String) async throws {
        connectionState = .connecting

        #if os(iOS)
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        // Mark as accessory hotspot so iOS maintains active cellular data for internet
        // while connected to camera Wi-Fi.
        configuration.joinOnce = true

        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
            currentSSID = ssid
            connectionState = .connected
        } catch {
            let message = error.localizedDescription
            // Joining an already joined network reports "already associated".
            if message.localizedCaseInsensitiveContains("already") {
                currentSSID = ssid
                connectionState = .connected
                return
            }
            connectionState = .error(message)
            throw GoProError.wifiJoinFailed(message)
        }
        #else
        throw GoProError.wifiJoinFailed("Hotspot configuration is iOS only")
        #endif
    }

    /// Ask the system to forget the camera hotspot.
    public func forget(ssid: String) {
        #if os(iOS)
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        #endif
        if currentSSID == ssid {
            currentSSID = nil
            connectionState = .disconnected
        }
    }

    /// SSID of the WiFi network the device is on, when iOS allows reading it.
    /// Reading it needs the access WiFi information entitlement or location
    /// permission; `nil` means unknown, not "not connected".
    public func refreshCurrentSSID() async {
        #if os(iOS)
        if let network = try? await NEHotspotNetwork.fetchCurrent() {
            currentSSID = network.ssid
        }
        #endif
    }

    /// True when the camera answers on its HTTP API.
    ///
    /// Probe instead of trusting the WiFi state: the phone can be on the camera
    /// hotspot while the camera is still booting its HTTP server.
    public func isCameraReachable() async -> Bool {
        // Try Open GoPro first, fall back to the legacy gpControl path.
        do {
            try await probe(path: "/gopro/camera/info")
            connectionState = .connected
            return true
        } catch {
            do {
                try await probe(path: "/gp/gpControl")
                connectionState = .connected
                return true
            } catch {
                return false
            }
        }
    }

    /// Probe one HTTP path on the camera.
    private func probe(path: String) async throws {
        guard let url = URL(string: "http://\(Self.cameraHost)\(path)") else {
            throw GoProError.cameraUnreachable
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        let (_, response) = try await probeSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoProError.cameraUnreachable
        }
    }

    /// Best-effort reachability check used by the UI before opening camera features.
    public func refreshConnectionState() async {
        if await isCameraReachable() {
            connectionState = .connected
        } else if connectionState == .connected {
            connectionState = .disconnected
        }
    }
}
