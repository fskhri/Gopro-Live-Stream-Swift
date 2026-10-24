import Foundation

// MARK: - Models

public struct MediaList: Codable, Sendable {
    public var id: String
    public var media: [MediaDirectory]

    public init(id: String = "", media: [MediaDirectory] = []) {
        self.id = id
        self.media = media
    }
}

public struct MediaDirectory: Codable, Sendable {
    /// Directory name on the SD card, e.g. "100GOPRO".
    public var directory: String
    public var files: [MediaFile]

    enum CodingKeys: String, CodingKey {
        case directory = "d"
        case files = "fs"
    }

    public init(directory: String = "", files: [MediaFile] = []) {
        self.directory = directory
        self.files = files
    }
}

public struct MediaFile: Codable, Sendable {
    public var name: String
    public var created: Int64
    public var modified: Int64
    public var size: String
    public var glrv: Int?
    public var ls: Int?
    public var groupId: String?

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case created = "cre"
        case modified = "mod"
        case size = "s"
        case glrv
        case ls
        case groupId = "g"
    }

    public init(
        name: String = "",
        created: Int64 = 0,
        modified: Int64 = 0,
        size: String = "",
        glrv: Int? = nil,
        ls: Int? = nil,
        groupId: String? = nil
    ) {
        self.name = name
        self.created = created
        self.modified = modified
        self.size = size
        self.glrv = glrv
        self.ls = ls
        self.groupId = groupId
    }

    /// Byte size when the camera reports one, `nil` when it reports "".
    public var byteSize: Int64? { Int64(size) }

    public var isVideo: Bool {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".mp4") || lowered.hasSuffix(".360")
    }
}

public struct CameraState: Sendable {
    public var status: [String: Int]
    public var settings: [String: Int]
}

public struct PresetList: Codable, Sendable {
    public var groups: [PresetGroupData]

    enum CodingKeys: String, CodingKey {
        case groups = "presetGroupArray"
    }

    public init(groups: [PresetGroupData] = []) {
        self.groups = groups
    }
}

public struct PresetGroupData: Codable, Sendable {
    public var id: Int
    public var presets: [PresetData]

    enum CodingKeys: String, CodingKey {
        case id
        case presets = "presetArray"
    }

    public init(id: Int = 0, presets: [PresetData] = []) {
        self.id = id
        self.presets = presets
    }
}

public struct PresetData: Codable, Identifiable, Sendable {
    public var id: Int
    public var mode: Int
    public var titleId: Int
    public var icon: Int
    public var isModified: Bool
    public var isFixed: Bool
    public var settings: [PresetSetting]

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case titleId
        case icon
        case isModified
        case isFixed
        case settings = "settingArray"
    }

    public init(
        id: Int = 0,
        mode: Int = 0,
        titleId: Int = 0,
        icon: Int = 0,
        isModified: Bool = false,
        isFixed: Bool = false,
        settings: [PresetSetting] = []
    ) {
        self.id = id
        self.mode = mode
        self.titleId = titleId
        self.icon = icon
        self.isModified = isModified
        self.isFixed = isFixed
        self.settings = settings
    }

    /// Preset name is not sent by the camera; it is derived from the icon id.
    public var title: String { PresetIcon.displayName(forIcon: icon) }
}

public struct PresetSetting: Codable, Equatable, Sendable {
    public var id: Int
    public var value: Int

    public init(id: Int = 0, value: Int = 0) {
        self.id = id
        self.value = value
    }
}

// MARK: - API client

/// HTTP client for the camera's local API on `10.5.5.9`.
///
/// Port of `wifi/GoProWifiApi.kt`. Every mutating call tries the legacy
/// gpControl path first, then the Open GoPro path, matching the Android order.
public final class GoProWifiAPI {
    public static let cameraHost = "10.5.5.9"
    private static let baseURL = "http://\(cameraHost)"

    private let session: URLSession
    private let decoder = JSONDecoder()

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession has no separate connect timeout; request timeout covers both.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    // MARK: Shutter

    public func shutterStart() async throws {
        try await sendCommand(first: "/gp/gpControl/command/shutter?p=1", fallback: "/gopro/camera/shutter/start")
    }

    public func shutterStop() async throws {
        try await sendCommand(first: "/gp/gpControl/command/shutter?p=0", fallback: "/gopro/camera/shutter/stop")
    }

    // MARK: Mode / preset

    public func setPresetGroup(_ group: PresetGroup) async throws {
        let modeId = group.modeId
        try await sendCommand(
            first: "/gp/gpControl/command/sub_mode?mode=\(modeId)&sub_mode=0",
            fallback: "/gopro/camera/presets/set_group?id=\(group.id)"
        )
    }

    public func setPreset(presetId: Int) async throws {
        try await sendCommand(first: "/gopro/camera/presets/load?id=\(presetId)")
    }

    public func getPresets() async throws -> PresetList {
        let body = try await get("/gopro/camera/presets/get")
        return try decode(PresetList.self, from: body)
    }

    // MARK: Settings

    public func setSetting(settingId: Int, value: Int) async throws {
        try await sendCommand(
            first: "/gp/gpControl/setting/\(settingId)/\(value)",
            fallback: "/gopro/camera/setting?setting=\(settingId)&option=\(value)"
        )
    }

    // MARK: Control

    public func sleep() async throws {
        try await sendCommand(first: "/gp/gpControl/command/system/sleep", fallback: "/gopro/camera/control/sleep")
    }

    public func setDateTime() async throws {
        let now = Int(Date().timeIntervalSince1970)
        try await sendCommand(first: "/gopro/camera/set_date_time?date_time=\(now)")
    }

    public func locate(enable: Bool) async throws {
        let flag = enable ? 1 : 0
        try await sendCommand(
            first: "/gp/gpControl/command/system/locate?p=\(flag)",
            fallback: "/gopro/camera/control/highlight?mode=\(flag)"
        )
    }

    // MARK: Status and hardware info

    /// Camera status and settings. Tries gpControl (Hero 5 to 8) then Open GoPro (Hero 9+).
    public func getState() async throws -> CameraState {
        var body = try? await get("/gp/gpControl/status")
        if body == nil {
            body = try? await get("/gopro/camera/state")
        }
        guard let body else { throw GoProError.cameraUnreachable }
        return try Self.parseState(body)
    }

    /// Model, serial, firmware, MAC, SSID. Tries gpControl then Open GoPro.
    public func getHardwareInfo() async throws -> [String: String] {
        if let body = try? await get("/gp/gpControl"),
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let info = root["info"] as? [String: Any] {
            return info.compactMapValues { $0 as? String }
        }

        if let body = try? await get("/gopro/camera/info"),
           let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            var result: [String: String] = [:]
            for (key, value) in root {
                if let text = value as? String {
                    result[key] = text
                }
            }
            return result
        }

        throw GoProError.cameraUnreachable
    }

    // MARK: Media

    public func getMediaList() async throws -> MediaList {
        var body = try? await get("/gp/gpMediaList")
        if body == nil {
            body = try? await get("/gopro/media/list")
        }
        guard let body else { throw GoProError.cameraUnreachable }
        return try decode(MediaList.self, from: body)
    }

    public func mediaURL(directory: String, filename: String) -> URL? {
        URL(string: "\(Self.baseURL)/videos/DCIM/\(directory)/\(filename)")
    }

    public func thumbnailURL(directory: String, filename: String) -> URL? {
        URL(string: "\(Self.baseURL)/gopro/media/thumbnail?path=\(directory)/\(filename)")
    }

    public func screennailURL(directory: String, filename: String) -> URL? {
        URL(string: "\(Self.baseURL)/gopro/media/screennail?path=\(directory)/\(filename)")
    }

    public func deleteMedia(directory: String, filename: String) async throws {
        try await sendCommand(
            first: "/gp/gpControl/command/storage/delete?p=\(directory)/\(filename)",
            fallback: "/gopro/media/delete/file?path=\(directory)/\(filename)"
        )
    }

    public func deleteAllMedia() async throws {
        try await sendCommand(
            first: "/gp/gpControl/command/storage/delete/all",
            fallback: "/gopro/media/delete/all"
        )
    }

    /// Download a media file.
    /// `progress` fires with 0.0 when the transfer starts and 1.0 when the file
    /// is on disk; byte-level progress is left to the UI layer.
    public func download(
        directory: String,
        filename: String,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let url = mediaURL(directory: directory, filename: filename) else {
            throw GoProError.cameraUnreachable
        }

        progress?(0.0)
        let (tempURL, response) = try await session.download(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoProError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: tempURL, to: destination)
        progress?(1.0)
    }

    // MARK: Live preview control

    /// Ask the camera to start its UDP preview stream (port 8554).
    /// Hero 6 answers the plain restart call; Hero 9+ needs the Open GoPro path.
    public func startPreview() async throws {
        do {
            try await sendCommand(first: "/gp/gpControl/execute?p1=gpStream&c1=restart")
        } catch {
            try await sendCommand(
                first: "/gp/gpControl/execute?p1=gpStream&a1=proto_v2&c1=restart",
                fallback: "/gopro/camera/stream/start"
            )
        }
    }

    public func stopPreview() async throws {
        try await sendCommand(
            first: "/gp/gpControl/execute?p1=gpStream&c1=stop",
            fallback: "/gopro/camera/stream/stop"
        )
    }

    // MARK: Low level

    /// Try `first`, fall back to `fallback` when the camera rejects or misses it.
    private func sendCommand(first: String, fallback: String? = nil) async throws {
        do {
            _ = try await get(first)
        } catch {
            guard let fallback else { throw error }
            _ = try await get(fallback)
        }
    }

    @discardableResult
    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: "\(Self.baseURL)\(path)") else {
            throw GoProError.cameraUnreachable
        }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw GoProError.cameraUnreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoProError.invalidResponse(http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GoProError.decodingFailed(String(describing: error))
        }
    }

    /// Camera sends `{"status":{"70":45,...},"settings":{...}}` with numeric string keys.
    static func parseState(_ data: Data) throws -> CameraState {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GoProError.decodingFailed("State is not a JSON object")
        }

        var status: [String: Int] = [:]
        var settings: [String: Int] = [:]

        if let statusObject = root["status"] as? [String: Any] {
            for (key, value) in statusObject {
                if let number = value as? NSNumber {
                    status[key] = number.intValue
                }
            }
        }
        if let settingsObject = root["settings"] as? [String: Any] {
            for (key, value) in settingsObject {
                if let number = value as? NSNumber {
                    settings[key] = number.intValue
                }
            }
        }

        // Older firmware reports battery as bars (0...3) instead of a percentage.
        let batteryPercent = status["\(StatusIds.batteryLevel)"] ?? 0
        if batteryPercent <= 0, let bars = status["\(StatusIds.internalBatteryLevel)"] {
            status["\(StatusIds.batteryLevel)"] = Self.batteryPercent(fromBars: bars)
        }

        return CameraState(status: status, settings: settings)
    }

    /// Camera battery bars to percentage, same steps the Android app used.
    static func batteryPercent(fromBars bars: Int) -> Int {
        switch bars {
        case 3: return 100
        case 2: return 65
        case 1: return 35
        default: return 10
        }
    }
}
