import Foundation

/// GoPro camera model table, reverse engineered from GoPro Quik `CameraModel.java`.
/// Port of `camera/GoProModel.kt`.
public enum GoProModel: Int, CaseIterable, Sendable {
    case hero2 = 1
    case hero3White = 2
    case hero3Silver = 3
    case hero3Black = 4
    case hero3PlusSilver = 10
    case hero3PlusBlack = 11
    case hero4Silver = 12
    case hero4Black = 13
    case hero = 14
    case heroPlusLCD = 15
    case hero4Session = 16
    case heroPlus = 17
    case hero5Black = 19
    case hero5Session = 21
    case fusion = 22
    case hero6Black = 24
    case hero7Black = 30
    case hero7White = 32
    case hero7Silver = 33
    case hero2018 = 34
    case hero8Black = 50
    case max = 51
    case hero9Black = 55
    case hero10Black = 57
    case hero11Black = 58
    case hero11BlackMini = 60
    case hero12Black = 62
    case hero13Black = 65
    case hero2024 = 66
    case litHero = 70
    case pebbles = 64
    case sandbar = 69
    case sandbarLite = 71

    /// Model number reported by the camera.
    public var modelNumber: Int { rawValue }

    /// Firmware prefix reported by the camera, e.g. "HD6.01".
    public var modelString: String {
        switch self {
        case .hero2: return "HD2.01"
        case .hero3White: return "HD3.01"
        case .hero3Silver: return "HD3.02"
        case .hero3Black: return "HD3.03"
        case .hero3PlusSilver: return "HD3.10"
        case .hero3PlusBlack: return "HD3.11"
        case .hero4Silver: return "HD4.01"
        case .hero4Black: return "HD4.02"
        case .hero: return "HD3.20"
        case .heroPlusLCD: return "HD3.21"
        case .hero4Session: return "HX1.01"
        case .heroPlus: return "HD3.22"
        case .hero5Black: return "HD5.02"
        case .hero5Session: return "HD5.03"
        case .fusion: return "FS1.04"
        case .hero6Black: return "HD6.01"
        case .hero7Black: return "HD7.01"
        case .hero7White: return "H18.02"
        case .hero7Silver: return "H18.03"
        case .hero2018: return "H18.01"
        case .hero8Black: return "HD8.01"
        case .max: return "H19.03"
        case .hero9Black: return "HD9.01"
        case .hero10Black: return "H21.01"
        case .hero11Black: return "H22.01"
        case .hero11BlackMini: return "H22.03"
        case .hero12Black: return "H23.01"
        case .hero13Black: return "H24.01"
        case .hero2024: return "H24.03"
        case .litHero: return "H25.03"
        case .pebbles: return "H24.02"
        case .sandbar: return "H26.01"
        case .sandbarLite: return "H26.02"
        }
    }

    public var displayName: String {
        switch self {
        case .hero2: return "HERO2"
        case .hero3White: return "HERO3 White"
        case .hero3Silver: return "HERO3 Silver"
        case .hero3Black: return "HERO3 Black"
        case .hero3PlusSilver: return "HERO3+ Silver"
        case .hero3PlusBlack: return "HERO3+ Black"
        case .hero4Silver: return "HERO4 Silver"
        case .hero4Black: return "HERO4 Black"
        case .hero: return "HERO"
        case .heroPlusLCD: return "HERO+ LCD"
        case .hero4Session: return "HERO4 Session"
        case .heroPlus: return "HERO+"
        case .hero5Black: return "HERO5 Black"
        case .hero5Session: return "HERO5 Session"
        case .fusion: return "Fusion"
        case .hero6Black: return "HERO6 Black"
        case .hero7Black: return "HERO7 Black"
        case .hero7White: return "HERO7 White"
        case .hero7Silver: return "HERO7 Silver"
        case .hero2018: return "HERO"
        case .hero8Black: return "HERO8 Black"
        case .max: return "MAX"
        case .hero9Black: return "HERO9 Black"
        case .hero10Black: return "HERO10 Black"
        case .hero11Black: return "HERO11 Black"
        case .hero11BlackMini: return "HERO11 Black Mini"
        case .hero12Black: return "HERO12 Black"
        case .hero13Black: return "HERO13 Black"
        case .hero2024: return "HERO"
        case .litHero: return "LIT HERO"
        case .pebbles: return "MAX2"
        case .sandbar: return "MISSION 1 PRO"
        case .sandbarLite: return "MISSION 1"
        }
    }

    public static func from(modelNumber: Int) -> GoProModel? {
        GoProModel(rawValue: modelNumber)
    }

    public static func from(modelString string: String) -> GoProModel? {
        let clean = string.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }

        if let exact = allCases.first(where: { $0.modelString.caseInsensitiveCompare(clean) == .orderedSame }) {
            return exact
        }
        if let named = allCases.first(where: { $0.displayName.caseInsensitiveCompare(clean) == .orderedSame }) {
            return named
        }
        if let hexValue = Int(clean, radix: 16), let model = from(modelNumber: hexValue) {
            return model
        }
        if let decimalValue = Int(clean, radix: 10), let model = from(modelNumber: decimalValue) {
            return model
        }
        return nil
    }

    /// Human-readable model name from whatever the camera reported.
    /// Falls back to the raw string unless it looks like hex model garbage.
    public static func displayName(raw: String?, fallback: String = "GoPro") -> String {
        guard let raw else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return fallback }

        if let model = from(modelString: trimmed) {
            return model.displayName
        }

        // Firmware strings look like "HD6.01.02.10".
        for model in allCases where trimmed.lowercased().hasPrefix(model.modelString.lowercased()) {
            return model.displayName
        }

        // Hex model garbage such as "00000018" is not worth showing.
        if trimmed.count >= 6, trimmed.allSatisfy({ $0.isHexDigit }) {
            return fallback
        }

        return trimmed
    }
}
