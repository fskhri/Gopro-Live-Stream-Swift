import Foundation

/// One RTMP message, after its chunks have been reassembled.
public struct GoProRtmpMessage: Equatable, Sendable {
    public var timestamp: UInt32
    public var type: UInt8
    public var streamID: UInt32
    public var payload: Data

    public init(timestamp: UInt32, type: UInt8, streamID: UInt32, payload: Data) {
        self.timestamp = timestamp
        self.type = type
        self.streamID = streamID
        self.payload = payload
    }

    /// RTMP keeps audio, video and commands in separate message types.
    public enum Kind: UInt8 {
        case setChunkSize = 1
        case acknowledgement = 3
        case userControl = 4
        case windowAcknowledgementSize = 5
        case setPeerBandwidth = 6
        case audio = 8
        case video = 9
        case dataAMF0 = 18
        case commandAMF0 = 20
    }

    public var kind: Kind? { Kind(rawValue: type) }
}

/// Chunk stream ids used by the session.
///
/// The values are the ones every RTMP implementation uses for these messages:
/// 2 for protocol control, 3 for commands, 4 for audio, 6 for video.
public enum GoProRtmpChannel {
    public static let control: UInt8 = 2
    public static let command: UInt8 = 3
    public static let audio: UInt8 = 4
    public static let video: UInt8 = 6
}

/// Serializes messages into RTMP chunks.
///
/// Only formats 0 and 3 are written. Format 0 carries the full header, so every
/// message is self-describing and no delta state can drift; format 3 continues a
/// message that does not fit in one chunk.
public struct GoProRtmpMessageWriter: Sendable {
    /// Payload bytes per chunk. Larger chunks mean fewer headers; 4096 is what
    /// most implementations settle on for live video.
    public var chunkSize: Int

    public init(chunkSize: Int = 4096) {
        self.chunkSize = max(1, chunkSize)
    }

    public func message(
        channel: UInt8,
        timestamp: UInt32,
        type: UInt8,
        streamID: UInt32,
        payload: Data
    ) -> Data {
        // 0xFFFFFF is the escape value that announces an extended timestamp.
        let extended = timestamp >= 0x00FF_FFFF
        var out = Data()
        out.reserveCapacity(payload.count + 16)

        // Basic header: format 0 plus the channel id, one byte for 2...63.
        out.append(channel & 0x3F)
        Self.appendUInt24(extended ? 0x00FF_FFFF : timestamp, to: &out)
        Self.appendUInt24(UInt32(min(payload.count, 0xFF_FFFF)), to: &out)
        out.append(type)
        Self.appendUInt32LE(streamID, to: &out)
        if extended {
            Self.appendUInt32BE(timestamp, to: &out)
        }

        var offset = payload.startIndex
        let firstEnd = min(offset + chunkSize, payload.endIndex)
        out.append(payload[offset..<firstEnd])
        offset = firstEnd

        while offset < payload.endIndex {
            // Format 3: basic header only, plus the extended timestamp when the
            // message header declared one.
            out.append(0xC0 | (channel & 0x3F))
            if extended {
                Self.appendUInt32BE(timestamp, to: &out)
            }
            let end = min(offset + chunkSize, payload.endIndex)
            out.append(payload[offset..<end])
            offset = end
        }
        return out
    }

    /// Set Chunk Size, the control message that tells the peer how large the
    /// chunks after it may be.
    public func setChunkSize(_ size: Int) -> Data {
        var payload = Data()
        Self.appendUInt32BE(UInt32(size & 0x7FFF_FFFF), to: &payload)
        return message(
            channel: GoProRtmpChannel.control,
            timestamp: 0,
            type: GoProRtmpMessage.Kind.setChunkSize.rawValue,
            streamID: 0,
            payload: payload
        )
    }

    static func appendUInt24(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func appendUInt32BE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

/// Reassembles messages from a byte stream of RTMP chunks.
///
/// Only what a publishing client has to understand: a server sends protocol
/// control, acknowledgements and the answers to the commands it was given.
public final class GoProRtmpMessageParser {
    /// Chunk size in force for the incoming direction.
    public private(set) var chunkSize = 128

    private struct ChannelState {
        var timestamp: UInt32 = 0
        var length: Int = 0
        var type: UInt8 = 0
        var streamID: UInt32 = 0
        var extendedTimestamp = false
    }

    private var buffer = Data()
    private var states: [UInt8: ChannelState] = [:]
    /// Message currently being assembled, and the channel it rides on.
    private var inProgress: (channel: UInt8, state: ChannelState)?
    private var assembled = Data()

    public init() {}

    /// Add received bytes.
    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Bytes read but not yet turned into a message.
    public var bufferedByteCount: Int { buffer.count }

    /// Next complete message, or `nil` while more bytes are needed.
    public func nextMessage() -> GoProRtmpMessage? {
        while let chunk = readChunk() {
            guard assembled.count >= chunk.state.length else { continue }

            let message = GoProRtmpMessage(
                timestamp: chunk.state.timestamp,
                type: chunk.state.type,
                streamID: chunk.state.streamID,
                payload: Data(assembled.prefix(chunk.state.length))
            )
            assembled.removeAll(keepingCapacity: true)
            inProgress = nil
            return message
        }
        return nil
    }

    private struct Chunk {
        var state: ChannelState
    }

    /// Read one chunk header plus the payload it carries, appending the payload
    /// to `assembled`.
    ///
    /// Returns `nil` when the buffered bytes do not hold a whole chunk yet.
    private func readChunk() -> Chunk? {
        var index = buffer.startIndex
        guard buffer.count >= 1 else { return nil }

        let first = buffer[index]
        let format = (first >> 6) & 0x03
        var channel = first & 0x3F
        index += 1

        if channel == 0 {
            guard buffer.endIndex - index >= 1 else { return nil }
            channel = 64 &+ buffer[index]
            index += 1
        } else if channel == 1 {
            guard buffer.endIndex - index >= 2 else { return nil }
            channel = 64 &+ buffer[index] &+ (buffer[index + 1] << 8)
            index += 2
        }

        // A type-3 chunk continuing this channel's message keeps its header,
        // and repeats the extended timestamp when the header declared one.
        if format == 3, let current = inProgress, current.channel == channel {
            if current.state.extendedTimestamp {
                guard buffer.endIndex - index >= 4 else { return nil }
                index += 4
            }
            guard takePayload(of: current.state, from: index) != nil else { return nil }
            return Chunk(state: current.state)
        }

        let previous = states[channel]
        var state = previous ?? ChannelState()
        var extended = false

        switch format {
        case 0:
            guard buffer.endIndex - index >= 11 else { return nil }
            let marker = readUInt24(buffer, index)
            extended = marker == 0x00FF_FFFF
            state.timestamp = marker
            state.length = Int(readUInt24(buffer, index + 3))
            state.type = buffer[index + 6]
            state.streamID = readUInt32LE(buffer, index + 7)
            index += 11
        case 1:
            guard buffer.endIndex - index >= 7 else { return nil }
            let delta = readUInt24(buffer, index)
            extended = delta == 0x00FF_FFFF
            state.length = Int(readUInt24(buffer, index + 3))
            state.type = buffer[index + 6]
            if !extended { state.timestamp &+= delta }
            index += 7
        case 2:
            guard buffer.endIndex - index >= 3 else { return nil }
            let delta = readUInt24(buffer, index)
            extended = delta == 0x00FF_FFFF
            if !extended { state.timestamp &+= delta }
            index += 3
        default:
            // Format 3 with no message in progress repeats that channel's last
            // header, so there is nothing more to read.
            break
        }

        if extended {
            guard buffer.endIndex - index >= 4 else { return nil }
            let value = readUInt32BE(buffer, index)
            switch format {
            case 0: state.timestamp = value
            case 1, 2: state.timestamp &+= value
            default: break
            }
            index += 4
        }
        state.extendedTimestamp = extended

        states[channel] = state
        assembled.removeAll(keepingCapacity: true)
        inProgress = (channel: channel, state: state)

        guard takePayload(of: state, from: index) != nil else {
            // The header is parsed and remembered, but the payload has not
            // fully arrived. The next call resumes at the same state.
            return nil
        }
        return Chunk(state: state)
    }

    /// Append up to one chunk of payload for `state`, starting at `index`.
    ///
    /// Returns the index just past the payload, or `nil` when it has not fully
    /// arrived. `inProgress.state.length` already accounts for bytes taken by
    /// earlier chunks of the same message.
    private func takePayload(of state: ChannelState, from index: Data.Index) -> Data.Index? {
        let remaining = max(0, state.length - assembled.count)
        let take = min(chunkSize, remaining)
        guard buffer.endIndex - index >= take else { return nil }

        assembled.append(Data(buffer[index..<(index + take)]))
        let next = index + take
        buffer.removeFirst(next - buffer.startIndex)
        return next
    }

    /// Apply a Set Chunk Size message to the incoming direction.
    public func applyChunkSize(from message: GoProRtmpMessage) {
        guard message.type == GoProRtmpMessage.Kind.setChunkSize.rawValue,
              message.payload.count >= 4 else { return }
        let size = Int(readUInt32BE(message.payload, message.payload.startIndex))
        if size > 0 { chunkSize = size & 0x7FFF_FFFF }
    }

    private func readUInt24(_ data: Data, _ index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 16) | (UInt32(data[index + 1]) << 8) | UInt32(data[index + 2])
    }

    private func readUInt32BE(_ data: Data, _ index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }

    private func readUInt32LE(_ data: Data, _ index: Data.Index) -> UInt32 {
        UInt32(data[index]) | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24)
    }
}
