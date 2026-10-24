import Combine
import Foundation

/// Owns the app's shared services and the connected camera.
///
/// Replaces Hilt's `AppModule` and `camera/CameraRepository.kt`: one container
/// created by the app and injected through the SwiftUI environment.
@MainActor
public final class GoProServices: ObservableObject {
    public let central: GoProBluetoothCentral
    public let scanner: GoProScanner
    public let wifi: WifiConnectionManager
    public let api: GoProWifiAPI
    /// Live preview. Shares the app's HTTP client with `api`, so it is created
    /// here rather than per screen: the socket and the UDP port outlive the
    /// control screen.
    public let preview: GoProPreviewPlayer
    /// TikTok LIVE room API. Shares the transport with `live`, because both
    /// leave the camera's network for cellular.
    public let tiktok: GoProTikTokService
    /// Pushes the preview stream into a TikTok room.
    public let live: GoProLiveStreamer

    @Published public private(set) var connectedCamera: GoProCamera?
    @Published public private(set) var lastError: String?

    private let store: UserDefaults
    private static let lastDeviceKey = "gopro.lastDeviceIdentifier"
    private var isReconnecting = false

    public init(store: UserDefaults = .standard) {
        self.store = store
        self.central = GoProBluetoothCentral()
        self.wifi = WifiConnectionManager()
        self.api = GoProWifiAPI()
        self.preview = GoProPreviewPlayer(api: api)
        self.scanner = GoProScanner(central: central)
        // One transport for the room API and the push: both have to leave the
        // camera's hotspot for cellular.
        let transport = GoProTikTokTransport()
        let tiktok = GoProTikTokService(transport: transport)
        self.tiktok = tiktok
        self.live = GoProLiveStreamer(service: tiktok, transport: transport, preview: preview)
    }

    /// Identifier of the camera connected last, for reconnect shortcuts.
    public var lastDeviceIdentifier: UUID? {
        guard let raw = store.string(forKey: Self.lastDeviceKey) else { return nil }
        return UUID(uuidString: raw)
    }

    /// Reconnect to the previously used camera when it advertises again.
    public func reconnectToLastCamera() async -> GoProCamera? {
        guard connectedCamera == nil, !isReconnecting,
              let identifier = lastDeviceIdentifier,
              let device = scanner.devices.first(where: { $0.identifier == identifier }) else {
            return connectedCamera
        }
        isReconnecting = true
        let camera = await connect(to: device)
        isReconnecting = false
        return camera
    }

    public func storeLastCameraChoice(_ identifier: UUID?) {
        if let identifier {
            store.set(identifier.uuidString, forKey: Self.lastDeviceKey)
        } else {
            store.removeObject(forKey: Self.lastDeviceKey)
        }
    }

    /// Connect to a discovered camera and remember it.
    @discardableResult
    public func connect(to device: GoProDevice) async -> GoProCamera? {
        lastError = nil
        scanner.stopScan()

        let camera = GoProCamera(device: device, central: central, wifi: wifi, api: api)
        do {
            try await camera.connect()
            connectedCamera = camera
            storeLastCameraChoice(device.identifier)
            return camera
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    public func disconnect(forgetSession: Bool = false) async {
        await connectedCamera?.disconnect()
        connectedCamera = nil
        if forgetSession {
            store.removeObject(forKey: Self.lastDeviceKey)
        }
    }

    /// Connect straight to the camera hotspot without BLE, when the phone is
    /// already on the camera network.
    @discardableResult
    public func connectOverWiFiOnly() async -> GoProCamera? {
        lastError = nil
        guard await wifi.isCameraReachable() else {
            lastError = GoProError.cameraUnreachable.localizedDescription
            return nil
        }

        let device = GoProDevice(
            identifier: lastDeviceIdentifier ?? UUID(),
            name: "GoPro (WiFi)",
            isPaired: true
        )
        let camera = GoProCamera(device: device, central: central, wifi: wifi, api: api)
        camera.markWiFiOnly()
        await camera.refreshStatus()
        connectedCamera = camera
        return camera
    }
}
