import Foundation

/// Response types carried in the first byte of a defragmented query frame.
public enum GoProQueryResponseType: UInt8 {
    /// Status response for "get all status".
    case statusResponse = 0x13
    /// Registered status update.
    case statusUpdate = 0x53
    /// Long-form status update.
    case statusUpdateLong = 0x93
    /// Settings response for "get all settings".
    case settingsResponse = 0x12
    /// Registered settings update.
    case settingsUpdate = 0x52
    /// Long-form settings update.
    case settingsUpdateLong = 0x92
}

/// Result of parsing a complete query-response frame.
public struct GoProQueryUpdate: Equatable, Sendable {
    public var statuses: [Int: Int]
    public var settings: [Int: Int]
    public var responseType: UInt8

    public init(statuses: [Int: Int] = [:], settings: [Int: Int] = [:], responseType: UInt8) {
        self.statuses = statuses
        self.settings = settings
        self.responseType = responseType
    }
}

public enum GoProTLVParser {
    /// Parse a defragmented query-response frame into a status/settings update.
    ///
    /// Frame layout: `[responseType][statusByte?][id, len, value...]...`.
    /// `value` is big-endian, up to 8 bytes, treated as an integer.
    /// Returns `nil` for response types this app does not consume.
    public static func parseQueryResponse(_ frame: Data) -> GoProQueryUpdate? {
        guard let responseType = frame.first else { return nil }
        let entries = parseTLV(frame, startIndex: 1)

        switch GoProQueryResponseType(rawValue: responseType) {
        case .statusResponse, .statusUpdate, .statusUpdateLong:
            return GoProQueryUpdate(statuses: entries, responseType: responseType)
        case .settingsResponse, .settingsUpdate, .settingsUpdateLong:
            return GoProQueryUpdate(settings: entries, responseType: responseType)
        case nil:
            return nil
        }
    }

    /// Parse a setting-response frame. Same TLV layout, no registered type set.
    public static func parseSettingResponse(_ frame: Data) -> [Int: Int] {
        guard frame.count > 1 else { return [:] }
        return parseTLV(frame, startIndex: 1)
    }

    /// Parse Type-Length-Value entries. `startIndex` is an offset from the first byte.
    ///
    /// Some responses carry a status code (0x00 = success) right after the type
    /// byte; it is skipped before the TLV loop.
    public static func parseTLV(_ data: Data, startIndex: Int) -> [Int: Int] {
        let bytes = [UInt8](data)
        var result: [Int: Int] = [:]
        var index = startIndex

        if index < bytes.count, bytes[index] == 0 {
            index += 1
        }

        while index + 2 <= bytes.count {
            let id = Int(bytes[index])
            let length = Int(bytes[index + 1])
            index += 2

            guard index + length <= bytes.count else { break }

            var value = 0
            for offset in 0..<length {
                value = (value << 8) | Int(bytes[index + offset])
            }
            index += length

            result[id] = value
        }

        return result
    }
}
