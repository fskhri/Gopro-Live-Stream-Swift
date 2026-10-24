/// GoPro BLE command bytes.
/// Values match `ble/GoProCommands.kt` from the Android implementation.
public enum GoProCommands {
    // MARK: Shutter

    /// Start recording / take photo.
    public static let shutterOn: [UInt8] = [0x01, 0x01, 0x01]
    /// Stop recording.
    public static let shutterOff: [UInt8] = [0x01, 0x01, 0x00]

    // MARK: Power

    /// Power off / sleep.
    public static let powerOff: [UInt8] = [0x01, 0x05]
    /// Keep alive ping.
    public static let keepAlive: [UInt8] = [0x01, 0x5B]

    // MARK: WiFi AP

    /// Enable the camera WiFi AP.
    public static let wifiApOn: [UInt8] = [0x03, 0x17, 0x01, 0x01]
    /// Disable the camera WiFi AP.
    public static let wifiApOff: [UInt8] = [0x03, 0x17, 0x01, 0x00]

    // MARK: Modes

    public static let modeVideo: [UInt8] = [0x04, 0x3E, 0x02, 0x03, 0xE8]
    public static let modePhoto: [UInt8] = [0x04, 0x3E, 0x02, 0x03, 0xE9]
    public static let modeTimelapse: [UInt8] = [0x04, 0x3E, 0x02, 0x03, 0xEA]

    // MARK: Queries

    /// Query all status values.
    public static let queryAllStatus: [UInt8] = [0x01, 0x13]
    /// Query all settings.
    public static let queryAllSettings: [UInt8] = [0x01, 0x12]
    /// Register for status updates.
    public static let registerStatusUpdates: [UInt8] = [0x01, 0x53]
    /// Register for settings updates.
    public static let registerSettingsUpdates: [UInt8] = [0x01, 0x52]
    /// Unregister from status updates.
    public static let unregisterStatusUpdates: [UInt8] = [0x01, 0x73]

    // MARK: Builders

    /// Build a set-setting command.
    /// Format: `[0x03, settingId, 0x01, value]`.
    public static func setSetting(settingId: Int, value: Int) -> [UInt8] {
        [0x03, UInt8(truncatingIfNeeded: settingId), 0x01, UInt8(truncatingIfNeeded: value)]
    }

    /// Build a query for specific status IDs.
    /// Format: `[count + 1, 0x13, ids...]`.
    public static func queryStatus(_ statusIds: [Int]) -> [UInt8] {
        [UInt8(truncatingIfNeeded: statusIds.count + 1), 0x13]
            + statusIds.map { UInt8(truncatingIfNeeded: $0) }
    }
}

/// Numeric setting identifiers, matches `camera/CameraSettings.kt`.
public enum SettingIds {
    public static let resolution = 2
    public static let fps = 3
    public static let fov = 121
    public static let hyperSmooth = 135
    public static let hindsight = 167
    public static let duration = 172
    public static let timer = 173
    public static let photoMode = 191
    public static let timelapseInterval = 30
    public static let protune = 114
    public static let whiteBalance = 115
    public static let color = 116
    public static let isoMax = 102
    public static let isoMin = 75
    public static let sharpness = 117
    public static let evComp = 118
    public static let rawAudio = 139
    public static let windNoise = 168
}

/// Numeric status identifiers, matches `camera/CameraSettings.kt`.
public enum StatusIds {
    public static let internalBatteryPresent = 1
    public static let internalBatteryLevel = 2
    public static let externalBatteryPresent = 3
    public static let externalBatteryLevel = 4
    public static let systemHot = 6
    public static let systemBusy = 8
    public static let quickCapture = 9
    public static let encodingActive = 10
    public static let lcdLockActive = 11
    public static let sdCardStatus = 33
    public static let remainingPhotos = 34
    public static let remainingVideoTime = 35
    public static let numTotalPhotos = 38
    public static let numTotalVideos = 39
    public static let remainingSpace = 54
    public static let currentTimeMsec = 57
    public static let numGroupPhotos = 73
    public static let numGroupVideos = 74
    public static let batteryLevel = 70
    public static let currentMode = 89
    public static let currentSubmode = 90
    public static let currentPreset = 97
    public static let presetGroup = 98
    public static let cameraLocateActive = 45
    public static let mediaModStatus = 102
    public static let turboTransfer = 113
    public static let apState = 114
    public static let scheduledCapture = 123
}
