import Foundation

/// Setting and preset option tables.
/// Port of `camera/CameraSettings.kt`.
///
/// Each option carries the numeric id the camera expects and a label for the UI.

/// Camera capture modes, used by the mode switch and preset groups.
public enum PresetGroup: Int, CaseIterable, Identifiable, Sendable {
    case video = 1000
    case photo = 1001
    case timelapse = 1002

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .video: return "Video"
        case .photo: return "Photo"
        case .timelapse: return "Timelapse"
        }
    }

    /// Mode id used by the gpControl sub_mode command.
    public var modeId: Int {
        switch self {
        case .video: return 0
        case .photo: return 1
        case .timelapse: return 2
        }
    }

    public static func from(id: Int) -> PresetGroup {
        PresetGroup(rawValue: id) ?? .video
    }
}

// MARK: - Video

public enum VideoResolution: Int, CaseIterable, Identifiable, Sendable {
    case res53K = 100
    case res4K = 1
    case res4K43 = 18
    case res27K = 4
    case res27K43 = 6
    case res1080 = 9
    case res108043 = 28
    case res720 = 12

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .res53K: return "5.3K"
        case .res4K: return "4K"
        case .res4K43: return "4K 4:3"
        case .res27K: return "2.7K"
        case .res27K43: return "2.7K 4:3"
        case .res1080: return "1080p"
        case .res108043: return "1080p 4:3"
        case .res720: return "720p"
        }
    }

    public static func from(id: Int) -> VideoResolution {
        VideoResolution(rawValue: id) ?? .res4K
    }
}

public enum FrameRate: Int, CaseIterable, Identifiable, Sendable {
    case fps240 = 0
    case fps200 = 13
    case fps120 = 1
    case fps100 = 2
    case fps60 = 5
    case fps50 = 6
    case fps30 = 8
    case fps25 = 9
    case fps24 = 10

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .fps240: return "240"
        case .fps200: return "200"
        case .fps120: return "120"
        case .fps100: return "100"
        case .fps60: return "60"
        case .fps50: return "50"
        case .fps30: return "30"
        case .fps25: return "25"
        case .fps24: return "24"
        }
    }

    public static func from(id: Int) -> FrameRate {
        FrameRate(rawValue: id) ?? .fps30
    }
}

public enum FieldOfView: Int, CaseIterable, Identifiable, Sendable {
    case hyperview = 9
    case superView = 3
    case wide = 0
    case linear = 4
    case linearHorizonLeveling = 8
    case narrow = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .hyperview: return "HyperView"
        case .superView: return "SuperView"
        case .wide: return "Wide"
        case .linear: return "Linear"
        case .linearHorizonLeveling: return "Linear+HL"
        case .narrow: return "Narrow"
        }
    }

    public static func from(id: Int) -> FieldOfView {
        FieldOfView(rawValue: id) ?? .wide
    }
}

public enum HyperSmooth: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case on = 1
    case high = 2
    case boost = 3
    case autoBoost = 4

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .high: return "High"
        case .boost: return "Boost"
        case .autoBoost: return "Auto Boost"
        }
    }

    public static func from(id: Int) -> HyperSmooth {
        HyperSmooth(rawValue: id) ?? .on
    }
}

public enum Hindsight: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case sec15 = 1
    case sec30 = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .sec15: return "15s"
        case .sec30: return "30s"
        }
    }

    public static func from(id: Int) -> Hindsight {
        Hindsight(rawValue: id) ?? .off
    }
}

public enum Duration: Int, CaseIterable, Identifiable, Sendable {
    case noLimit = 0
    case sec15 = 1
    case sec30 = 2
    case min1 = 3
    case min5 = 4
    case min15 = 5
    case min30 = 6
    case hour1 = 7
    case hour2 = 8
    case hour3 = 9

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .noLimit: return "No Limit"
        case .sec15: return "15s"
        case .sec30: return "30s"
        case .min1: return "1 min"
        case .min5: return "5 min"
        case .min15: return "15 min"
        case .min30: return "30 min"
        case .hour1: return "1 hour"
        case .hour2: return "2 hours"
        case .hour3: return "3 hours"
        }
    }
}

public enum Timer: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case sec3 = 1
    case sec10 = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .sec3: return "3s"
        case .sec10: return "10s"
        }
    }
}

// MARK: - Photo

public enum PhotoMode: Int, CaseIterable, Identifiable, Sendable {
    case superPhoto = 0
    case hdr = 1
    case standard = 2
    case raw = 3

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .superPhoto: return "SuperPhoto"
        case .hdr: return "HDR"
        case .standard: return "Standard"
        case .raw: return "RAW"
        }
    }

    public static func from(id: Int) -> PhotoMode {
        PhotoMode(rawValue: id) ?? .standard
    }
}

public enum TimelapseInterval: Int, CaseIterable, Identifiable, Sendable {
    case interval05 = 0
    case interval1 = 1
    case interval2 = 2
    case interval5 = 3
    case interval10 = 4
    case interval30 = 5
    case interval60 = 6

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .interval05: return "0.5s"
        case .interval1: return "1s"
        case .interval2: return "2s"
        case .interval5: return "5s"
        case .interval10: return "10s"
        case .interval30: return "30s"
        case .interval60: return "60s"
        }
    }

    public static func from(id: Int) -> TimelapseInterval {
        TimelapseInterval(rawValue: id) ?? .interval1
    }
}

// MARK: - Protune

public enum ProtuneColor: Int, CaseIterable, Identifiable, Sendable {
    case vibrant = 0
    case natural = 1
    case flat = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .vibrant: return "Vibrant"
        case .natural: return "Natural"
        case .flat: return "Flat"
        }
    }
}

public enum WhiteBalance: Int, CaseIterable, Identifiable, Sendable {
    case auto = 0
    case wb3000K = 1
    case wb4000K = 5
    case wb4800K = 6
    case wb5500K = 2
    case wb6000K = 7
    case wb6500K = 3
    case native = 4

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .wb3000K: return "3000K"
        case .wb4000K: return "4000K"
        case .wb4800K: return "4800K"
        case .wb5500K: return "5500K"
        case .wb6000K: return "6000K"
        case .wb6500K: return "6500K"
        case .native: return "Native"
        }
    }
}

public enum ISOLevel: Int, CaseIterable, Identifiable, Sendable {
    case iso100 = 0
    case iso200 = 1
    case iso400 = 2
    case iso800 = 3
    case iso1600 = 4
    case iso3200 = 5
    case iso6400 = 6

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .iso100: return "100"
        case .iso200: return "200"
        case .iso400: return "400"
        case .iso800: return "800"
        case .iso1600: return "1600"
        case .iso3200: return "3200"
        case .iso6400: return "6400"
        }
    }
}

public enum Sharpness: Int, CaseIterable, Identifiable, Sendable {
    case high = 0
    case medium = 1
    case low = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

public enum EVComp: Int, CaseIterable, Identifiable, Sendable {
    case minus2 = -4
    case minus1_5 = -3
    case minus1 = -2
    case minus0_5 = -1
    case zero = 0
    case plus0_5 = 1
    case plus1 = 2
    case plus1_5 = 3
    case plus2 = 4

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .minus2: return "-2.0"
        case .minus1_5: return "-1.5"
        case .minus1: return "-1.0"
        case .minus0_5: return "-0.5"
        case .zero: return "0"
        case .plus0_5: return "+0.5"
        case .plus1: return "+1.0"
        case .plus1_5: return "+1.5"
        case .plus2: return "+2.0"
        }
    }
}

// MARK: - Preset icons

public enum PresetIcon: Int, CaseIterable, Identifiable, Sendable {
    case video = 0
    case timelapse = 1
    case nightlapse = 2
    case photo = 3
    case nightPhoto = 4
    case burst = 5
    case standard = 70
    case activity = 71
    case cinematic = 72
    case ultraSloMo = 73
    case basic = 74
    case photoAlt = 75
    case liveBurst = 76
    case nightPhotoAlt = 77
    case timeWarp = 78
    case timelapseAlt = 79
    case nightlapseAlt = 80
    case starTrails = 81
    case lightPainting = 82
    case lightTrails = 83
    case fullFrame = 84

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .video: return "Video"
        case .timelapse: return "Timelapse"
        case .nightlapse: return "Night Lapse"
        case .photo: return "Photo"
        case .nightPhoto: return "Night Photo"
        case .burst: return "Burst"
        case .standard: return "Standard"
        case .activity: return "Activity"
        case .cinematic: return "Cinematic"
        case .ultraSloMo: return "Ultra Slo-Mo"
        case .basic: return "Basic"
        case .photoAlt: return "Photo"
        case .liveBurst: return "LiveBurst"
        case .nightPhotoAlt: return "Night Photo"
        case .timeWarp: return "TimeWarp"
        case .timelapseAlt: return "Timelapse"
        case .nightlapseAlt: return "Night Lapse"
        case .starTrails: return "Star Trails"
        case .lightPainting: return "Light Painting"
        case .lightTrails: return "Light Trails"
        case .fullFrame: return "Full Frame"
        }
    }

    public static func displayName(forIcon icon: Int) -> String {
        PresetIcon(rawValue: icon)?.label ?? "Preset"
    }
}
