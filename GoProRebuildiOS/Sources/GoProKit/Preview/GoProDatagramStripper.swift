import Foundation

/// Strips the 12-byte GoPro header from one preview datagram.
///
/// Port of the re-framing inside `GoProUdpDataSource.read()`. Each datagram is
/// a GoPro header followed by MPEG-TS, but raw datagrams break the `0x47` sync
/// pattern, so the header must be removed before the bytes reach a demuxer:
///
/// - bytes 0...8   : GoPro header prefix
/// - byte 9        : packet sequence counter, wraps 0...255
/// - bytes 10...11 : big-endian payload length, a multiple of 188
/// - byte 12       : first MPEG-TS sync byte
///
/// Two fallbacks are kept identical to Android:
///
/// 1. No sync byte at byte 12 means the datagram is not a preview packet at
///    all, so it is handed to the demuxer untouched, header included.
/// 2. A sync byte is present but the declared length is out of range, so every
///    byte after the header is used. That includes framing padding, which the
///    demuxer skips while resynchronizing.
public enum GoProDatagramStripper {
    public enum StripError: Error, Equatable {
        case empty
        case tooShort(Int)
    }

    /// Result of stripping one datagram.
    public struct Result: Equatable {
        /// MPEG-TS bytes, copied out of the datagram.
        public let payload: Data
        /// Length of the datagram this payload came from.
        public let datagramLength: Int
        /// Trailing bytes left unconsumed, non-zero only for padded datagrams.
        public let padding: Int
        /// Whether the declared length was trusted, or the fallback was used.
        public let usedDeclaredLength: Bool
    }

    /// - Throws: `StripError` when the datagram cannot hold a preview packet.
    public static func strip(_ datagram: Data) throws -> Result {
        guard !datagram.isEmpty else { throw StripError.empty }

        let headerSize = GoProPreviewConfiguration.headerSize
        guard datagram.count > headerSize else { throw StripError.tooShort(datagram.count) }

        let start = datagram.startIndex
        let syncIndex = start + headerSize

        // Fallback 1: not framed as a GoPro preview packet.
        guard datagram[syncIndex] == GoProPreviewConfiguration.syncByte else {
            return Result(payload: Data(datagram), datagramLength: datagram.count, padding: 0, usedDeclaredLength: false)
        }

        let available = datagram.count - headerSize
        let declared = (Int(datagram[start + 10]) << 8) | Int(datagram[start + 11])
        let declaredIsUsable = declared >= 1 && declared <= available
        let length = declaredIsUsable ? declared : available

        return Result(
            payload: Data(datagram[syncIndex..<(syncIndex + length)]),
            datagramLength: datagram.count,
            padding: available - length,
            usedDeclaredLength: declaredIsUsable
        )
    }

    /// Build a framed datagram for tests and for replaying recorded streams.
    ///
    /// - Parameters:
    ///   - payload: MPEG-TS bytes; zero-padded to a whole 188-byte packet.
    ///   - sequence: value written to byte 9, wrapping at 256.
    ///   - declaredLength: override for the big-endian length field; defaults to
    ///     the padded payload length.
    public static func frame(payload: Data, sequence: Int, declaredLength: Int? = nil) -> Data {
        let packetSize = GoProPreviewConfiguration.transportStreamPacketSize
        let padding = (packetSize - (payload.count % packetSize)) % packetSize
        let padded = payload + Data(repeating: 0, count: padding)
        let length = declaredLength ?? padded.count

        var datagram = Data(capacity: GoProPreviewConfiguration.headerSize + padded.count)
        datagram.append(contentsOf: [
            0, 0, 0, 0, 0, 0, 0, 0, 0,
            UInt8(truncatingIfNeeded: sequence),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ])
        datagram.append(padded)
        return datagram
    }
}
