import Foundation

/// AMF0 encoding for the RTMP command messages a `publish` session sends.
///
/// The values an AMF0 command uses are few: a transaction number, a name, the
/// stream key and a command object. Encoding them is enough to reach a live
/// ingest; decoding is used to read the `_result` and `_error` answers back.
public enum GoProAmf0 {

    // MARK: - Encoding

    public static func string(_ value: String) -> Data {
        var data = Data([0x02])
        appendUInt16(UInt16(value.utf8.count), to: &data)
        data.append(Data(value.utf8))
        return data
    }

    public static func number(_ value: Double) -> Data {
        var data = Data([0x00])
        appendDouble(value, to: &data)
        return data
    }

    public static func boolean(_ value: Bool) -> Data {
        Data([0x01, value ? 1 : 0])
    }

    public static func null() -> Data {
        Data([0x05])
    }

    public static func undefined() -> Data {
        Data([0x06])
    }

    /// An object marker, then the property pairs, then the end marker.
    public static func object(_ pairs: [(String, Data)]) -> Data {
        var data = Data([0x03])
        appendPairs(pairs, to: &data)
        return data
    }

    /// An ECMA array: marker, 32-bit count, then the same properties as an
    /// object. The count is advisory, so it is written as the pair count.
    public static func ecmaArray(_ pairs: [(String, Data)]) -> Data {
        var data = Data([0x08])
        appendUInt32(UInt32(pairs.count), to: &data)
        appendPairs(pairs, to: &data)
        return data
    }

    private static func appendPairs(_ pairs: [(String, Data)], to data: inout Data) {
        for (name, value) in pairs {
            appendUInt16(UInt16(name.utf8.count), to: &data)
            data.append(Data(name.utf8))
            data.append(value)
        }
        data.append(contentsOf: [0x00, 0x00, 0x09])  // object end marker
    }

    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func appendDouble(_ value: Double, to data: inout Data) {
        var bigEndian = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - Decoding

    public enum Value: Equatable, Sendable {
        case number(Double)
        case boolean(Bool)
        case string(String)
        case object([(String, Value)])
        case ecmaArray([(String, Value)])
        case strictArray([Value])
        case null
        case undefined

        /// Written by hand: an array of name/value tuples does not synthesize
        /// `Equatable` on its own.
        public static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.number(let a), .number(let b)): return a == b
            case (.boolean(let a), .boolean(let b)): return a == b
            case (.string(let a), .string(let b)): return a == b
            case (.object(let a), .object(let b)): return pairsEqual(a, b)
            case (.ecmaArray(let a), .ecmaArray(let b)): return pairsEqual(a, b)
            case (.strictArray(let a), .strictArray(let b)): return a == b
            case (.null, .null): return true
            case (.undefined, .undefined): return true
            default: return false
            }
        }

        private static func pairsEqual(_ lhs: [(String, Value)], _ rhs: [(String, Value)]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }

        public var number: Double? {
            if case .number(let value) = self { return value }
            return nil
        }

        public var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public func property(_ name: String) -> Value? {
            switch self {
            case .object(let pairs), .ecmaArray(let pairs):
                return pairs.first { $0.0 == name }?.1
            default:
                return nil
            }
        }
    }

    /// Parse a run of AMF0 values, one per command argument.
    ///
    /// Trailing bytes that do not form a value are ignored rather than an
    /// error: servers pad responses, and a live push only needs the fields it
    /// can read.
    public static func decode(_ data: Data) -> [Value] {
        let bytes = [UInt8](data)
        var index = 0
        var values: [Value] = []

        while index < bytes.count {
            guard let value = decodeValue(bytes, at: &index) else { break }
            values.append(value)
        }
        return values
    }

    private static func decodeValue(_ bytes: [UInt8], at index: inout Int) -> Value? {
        guard index < bytes.count else { return nil }
        let marker = bytes[index]
        index += 1

        switch marker {
        case 0x00:
            guard index + 8 <= bytes.count else { return nil }
            let bits = bytes[index..<(index + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            index += 8
            return .number(Double(bitPattern: bits))

        case 0x01:
            guard index < bytes.count else { return nil }
            let value = bytes[index] != 0
            index += 1
            return .boolean(value)

        case 0x02:
            guard let text = decodeString(bytes, at: &index) else { return nil }
            return .string(text)

        case 0x03:
            guard let pairs = decodePairs(bytes, at: &index) else { return nil }
            return .object(pairs)

        case 0x05:
            return .null

        case 0x06:
            return .undefined

        case 0x08:
            guard index + 4 <= bytes.count else { return nil }
            index += 4  // advisory pair count
            guard let pairs = decodePairs(bytes, at: &index) else { return nil }
            return .ecmaArray(pairs)

        case 0x0A:
            guard index + 4 <= bytes.count else { return nil }
            let count = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 4
            var values: [Value] = []
            for _ in 0..<count {
                guard let value = decodeValue(bytes, at: &index) else { return nil }
                values.append(value)
            }
            return .strictArray(values)

        default:
            return nil
        }
    }

    private static func decodeString(_ bytes: [UInt8], at index: inout Int) -> String? {
        guard index + 2 <= bytes.count else { return nil }
        let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        index += 2
        guard index + length <= bytes.count else { return nil }
        let slice = bytes[index..<(index + length)]
        index += length
        return String(decoding: slice, as: UTF8.self)
    }

    private static func decodePairs(_ bytes: [UInt8], at index: inout Int) -> [(String, Value)]? {
        var pairs: [(String, Value)] = []
        while index < bytes.count {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            if length == 0 {
                // Object end marker, once the two remaining bytes are 0x09.
                index += 2
                guard index < bytes.count, bytes[index] == 0x09 else { return nil }
                index += 1
                return pairs
            }
            guard index + 2 + length <= bytes.count else { return nil }
            let name = String(decoding: bytes[(index + 2)..<(index + 2 + length)], as: UTF8.self)
            index += 2 + length
            guard let value = decodeValue(bytes, at: &index) else { return nil }
            pairs.append((name, value))
        }
        return nil
    }
}
