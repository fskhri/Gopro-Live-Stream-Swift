import Combine
import Foundation

/// Snapshot of the connected camera, mirrored from BLE status or the WiFi API.
public struct CameraStatus: Equatable, Sendable {
    public var isConnected = false
    public var isRecording = false
    public var batteryLevel = 0
    public var sdCardSpaceRemaining: Int64 = 0
    public var currentMode: PresetGroup = .video
    public var cameraInfo: CameraInfo?

    public init(
        isConnected: Bool = false,
        isRecording: Bool = false,
        batteryLevel: Int = 0,
        sdCardSpaceRemaining: Int64 = 0,
        currentMode: PresetGroup = .video,
        cameraInfo: CameraInfo? = nil
    ) {
        self.isConnected = isConnected
        self.isRecording = isRecording
        self.batteryLevel = batteryLevel
        self.sdCardSpaceRemaining = sdCardSpaceRemaining
        self.currentMode = currentMode
        self.cameraInfo = cameraInfo
    }
}

/// One connected camera. Port of `camera/GoProCamera.kt`.
///
/// Routes every control through WiFi when the hotspot is up, BLE otherwise,
/// so the same shutter button works with or without WiFi.
@MainActor
public final class GoProCamera: ObservableObject {
    public let device: GoProDevice

    @Published public private(set) var status = CameraStatus()
    @Published public private(set) var settings: [Int: Int] = [:]
    @Published public private(set) var bleState: BLEConnectionState = .disconnected
    @Published public private(set) var wifiState: WifiConnectionState = .disconnected

    public let ble: GoProBLEConnection
    public let wifi: WifiConnectionManager
    public let api: GoProWifiAPI

    private var wifiCredentials: WifiCredentials?
    private var bag = Set<AnyCancellable>()

    public init(device: GoProDevice, central: GoProBluetoothCentral, wifi: WifiConnectionManager, api: GoProWifiAPI) {
        self.device = device
        self.wifi = wifi
        self.api = api
        self.ble = GoProBLEConnection(central: central, device: device)

        ble.$statusMap
            .receive(on: RunLoop.main)
            .sink { [weak self] statusMap in
                self?.applyStatusMap(statusMap)
            }
            .store(in: &bag)

        ble.$settingsMap
            .receive(on: RunLoop.main)
            .sink { [weak self] settingsMap in
                guard let self, !settingsMap.isEmpty else { return }
                self.settings.merge(settingsMap) { _, new in new }
            }
            .store(in: &bag)

        ble.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.bleState = state
            }
            .store(in: &bag)

        wifi.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.wifiState = state
            }
            .store(in: &bag)
    }

    // MARK: - Connect / disconnect

    public func connect() async throws {
        try await ble.connect()

        let cameraInfo = await ble.getCameraInfo()
        status = CameraStatus(isConnected: true, cameraInfo: cameraInfo)

        // Credentials are read once and reused when WiFi is requested later.
        wifiCredentials = try? await ble.getWifiCredentials()
    }

    /// Enable the camera hotspot over BLE, then join it.
    public func connectWiFi() async throws {
        let credentials: WifiCredentials
        if let wifiCredentials {
            credentials = wifiCredentials
        } else if let fetched = try? await ble.getWifiCredentials() {
            credentials = fetched
            wifiCredentials = fetched
        } else {
            throw GoProError.wifiCredentialsUnavailable
        }

        try? await ble.enableWifiAp()
        // Camera needs a beat to bring the AP up.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        try await wifi.join(ssid: credentials.ssid, password: credentials.password)
        await refreshStatus()
    }

    public func disconnect() async {
        if let credentials = wifiCredentials {
            wifi.forget(ssid: credentials.ssid)
        }
        await ble.disconnect()
        status = CameraStatus()
    }

    // MARK: - Shutter and mode

    public func startRecording() async throws {
        if await wifi.isCameraReachable() {
            try await api.shutterStart()
        } else {
            try await ble.shutterOn()
        }
        status.isRecording = true
    }

    public func stopRecording() async throws {
        if await wifi.isCameraReachable() {
            try await api.shutterStop()
        } else {
            try await ble.shutterOff()
        }
        status.isRecording = false
    }

    public func setMode(_ mode: PresetGroup) async throws {
        if await wifi.isCameraReachable() {
            try await api.setPresetGroup(mode)
        } else {
            switch mode {
            case .video: try await ble.setModeVideo()
            case .photo: try await ble.setModePhoto()
            case .timelapse: try await ble.setModeTimelapse()
            }
        }
        status.currentMode = mode
    }

    public func setSetting(settingId: Int, value: Int) async throws {
        if await wifi.isCameraReachable() {
            try await api.setSetting(settingId: settingId, value: value)
        } else {
            try await ble.setSetting(settingId: settingId, value: value)
        }
        settings[settingId] = value
    }

    public func powerOff() async throws {
        if await wifi.isCameraReachable() {
            try await api.sleep()
        } else {
            try await ble.powerOff()
        }
    }

    /// Send a BLE keep alive so the camera stays awake while idle.
    public func keepAlive() async {
        let wifiUp = await wifi.isCameraReachable()
        guard !wifiUp else { return }
        try? await ble.keepAlive()
    }

    // MARK: - Status

    /// Mark the camera as connected without a BLE link (WiFi-only mode).
    public func markWiFiOnly() {
        status = CameraStatus(isConnected: true)
    }

    public func refreshStatus() async {
        if await wifi.isCameraReachable() {
            guard let state = try? await api.getState() else { return }
            applyStatusMap(Self.numericKeyed(state.status))
            settings.merge(Self.numericKeyed(state.settings)) { _, new in new }

            if status.cameraInfo?.firmware == "Unknown" || status.cameraInfo == nil,
               let hardware = try? await api.getHardwareInfo() {
                status.cameraInfo = CameraInfo(
                    model: GoProModel.displayName(raw: hardware["model_name"], fallback: status.cameraInfo?.model ?? device.name),
                    firmware: hardware["firmware_version"] ?? "Unknown",
                    serialNumber: hardware["serial_number"] ?? "Unknown"
                )
            }
        } else {
            try? await ble.queryAllStatus()
            try? await ble.queryAllSettings()
        }
    }

    /// Convert the camera's string-keyed status map to the Int-keyed map the
    /// BLE layer uses. Keys that are not numbers are dropped.
    private static func numericKeyed(_ map: [String: Int]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (key, value) in map {
            if let id = Int(key) {
                result[id] = value
            }
        }
        return result
    }

    private func applyStatusMap(_ map: [Int: Int]) {
        guard !map.isEmpty else { return }

        var next = status
        if let percent = map[StatusIds.batteryLevel] {
            next.batteryLevel = percent
        } else if let bars = map[StatusIds.internalBatteryLevel] {
            next.batteryLevel = GoProWifiAPI.batteryPercent(fromBars: bars)
        }
        if let recording = map[StatusIds.encodingActive] {
            next.isRecording = recording == 1
        }
        if let modeRaw = map[43] {
            // Key 43 is the capture mode: 0 video, 1 photo, 2 timelapse.
            switch modeRaw {
            case 0: next.currentMode = .video
            case 1: next.currentMode = .photo
            case 2: next.currentMode = .timelapse
            default: break
            }
        }
        if let space = map[StatusIds.remainingSpace] {
            next.sdCardSpaceRemaining = Int64(space) * 1024
        }
        status = next
    }
}
