import Foundation

/// Where a stream is pushed: host, port, application and stream key.
///
/// TikTok hands out one full `rtmp_push_url`, whose last path segment is the
/// credential and whose query string is part of the key. Splitting it here keeps
/// the URL shape in one place, because the query has to survive byte for byte.
public struct GoProRtmpEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    /// Application name: everything in the path except the last segment.
    public let app: String
    /// Last path segment plus the query string, sent to `publish` untouched.
    public let streamName: String
    public let usesTLS: Bool

    /// `rtmp://host:port/app`, the value the server expects in `connect`.
    public var tcUrl: String {
        let defaultPort: UInt16 = usesTLS ? 443 : 1935
        let portPart = port == defaultPort ? "" : ":\(port)"
        return "\(usesTLS ? "rtmps" : "rtmp")://\(host)\(portPart)/\(app)"
    }

    public init?(url: String) {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // Percent-encoded on purpose: a signed key's query must travel as it
        // arrived, not re-encoded from a decoded form.
        let path = components.percentEncodedPath
        var segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        let last = segments.removeLast()
        guard !last.isEmpty else { return nil }

        self.host = host
        self.usesTLS = scheme == "rtmps"
        self.port = UInt16(components.port ?? (scheme == "rtmps" ? 443 : 1935))
        self.app = segments.joined(separator: "/")
        self.streamName = components.percentEncodedQuery.map { "\(last)?\($0)" } ?? last
    }
}

/// A server notification about the publish stream.
public struct GoProRtmpStatusEvent: Equatable, Sendable {
    public let code: String
    public let description: String

    public init(code: String, description: String) {
        self.code = code
        self.description = description
    }

    /// Codes the server uses to say the stream will not work.
    public var isFailure: Bool {
        code.contains("Failed") || code.contains("Bad") || code.contains("Rejected")
            || code.contains("Denied")
    }
}

/// Everything that can go wrong while setting up or holding a publish.
public enum GoProRtmpError: Error, LocalizedError, Equatable {
    case handshake(String)
    case command(String)
    case refused(code: String, description: String)

    public var errorDescription: String? {
        switch self {
        case .handshake(let detail):
            return "The RTMP server did not accept the handshake. \(detail)"
        case .command(let detail):
            return "The RTMP server rejected a command. \(detail)"
        case .refused(_, let description):
            return description.isEmpty ? "The RTMP server refused the stream." : description
        }
    }
}

/// The byte stream an RTMP session runs on, narrowed to what the client uses.
public protocol GoProRtmpConnection: AnyObject, Sendable {
    func write(_ data: Data) async throws
    func read() async throws -> Data
    /// Read, returning `nil` when nothing arrived in time; the connection
    /// stays open either way.
    func read(waitingUpTo interval: TimeInterval) async throws -> Data?
    func close()
    func armDeadline(after interval: TimeInterval)
    func cancelDeadline()
}

extension GoProByteStream: GoProRtmpConnection {}

/// Serializes writes, so a video frame and a keepalive reply cannot interleave
/// halfway through a chunk.
private actor GoProRtmpWriter {
    private let connection: GoProRtmpConnection

    init(connection: GoProRtmpConnection) {
        self.connection = connection
    }

    func write(_ data: Data) async throws {
        try await connection.write(data)
    }
}

/// Pushes an FLV-tagged stream to an RTMP ingest.
///
/// Replaces the `librtmp` half of `ffmpeg -f flv -f rtmp` that Android relied
/// on. The handshake, the command sequence (`connect`, `createStream`,
/// `publish`) and the chunk framing are all here.
///
/// State is mutated from one task at a time: the setup phase, then the
/// single drain task. Media writes only touch the serializing actor.
public final class GoProRtmpClient: @unchecked Sendable {
    /// Reported when the server says something about the publish stream.
    public var onStatus: (@Sendable (GoProRtmpStatusEvent) -> Void)?

    /// Payload bytes per outgoing chunk.
    public var chunkSize: Int

    private let connection: GoProRtmpConnection
    private let writer: GoProRtmpWriter
    private let parser = GoProRtmpMessageParser()
    private var incoming = Data()

    private var receivedBytes = 0
    private var acknowledgedBytes = 0
    private var acknowledgementWindow = 0
    private var drainTask: Task<Void, Never>?
    private var isClosed = false

    private var publishStreamID: UInt32 = 1
    private var didPublish = false

    public init(connection: GoProRtmpConnection, chunkSize: Int = 4096) {
        self.connection = connection
        self.writer = GoProRtmpWriter(connection: connection)
        self.chunkSize = chunkSize
    }

    /// Handshake, then `connect`, `createStream` and `publish`.
    ///
    /// On return the server has accepted the stream key and media can be sent.
    public func publish(to endpoint: GoProRtmpEndpoint, metadataTimer: TimeInterval = 1.5) async throws {
        let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)

        // The whole setup has one deadline; once the server accepts the stream
        // it is dropped so an idle ingest cannot age the session out.
        connection.armDeadline(after: 15)
        try await handshake()

        // Tell the server the chunk size this side will use, and how much data
        // it may send before an acknowledgement is owed.
        try await send(chunker.setChunkSize(chunkSize))
        try await send(chunker.message(
            channel: GoProRtmpChannel.control,
            timestamp: 0,
            type: GoProRtmpMessage.Kind.windowAcknowledgementSize.rawValue,
            streamID: 0,
            payload: Self.uint32BE(UInt32(acknowledgementWindow == 0 ? Self.defaultWindow : acknowledgementWindow))
        ))
        try await send(chunker.message(
            channel: GoProRtmpChannel.control,
            timestamp: 0,
            type: GoProRtmpMessage.Kind.setPeerBandwidth.rawValue,
            streamID: 0,
            payload: Self.uint32BE(UInt32(Self.defaultWindow)) + Data([0x02])
        ))

        // connect: the server answers with _result carrying its capabilities.
        try await sendCommand(
            name: "connect",
            transaction: 1,
            streamID: 0,
            arguments: [
                GoProAmf0.object([
                    ("app", GoProAmf0.string(endpoint.app)),
                    ("type", GoProAmf0.string("nonprivate")),
                    ("tcUrl", GoProAmf0.string(endpoint.tcUrl)),
                    ("flashVer", GoProAmf0.string(Self.flashVersion)),
                    ("fpad", GoProAmf0.boolean(false)),
                    ("capabilities", GoProAmf0.number(15)),
                    // AAC (1024) + MP3 (32) + the rest of the audio codec bits,
                    // and H.264 for video. Advertising less makes some servers
                    // rewrite the stream.
                    ("audioCodecs", GoProAmf0.number(4071)),
                    ("videoCodecs", GoProAmf0.number(252)),
                    ("videoFunction", GoProAmf0.number(1)),
                    ("objectEncoding", GoProAmf0.number(0)),
                ]),
            ]
        )
        _ = try await awaitResult(transaction: 1)

        // Ask the server to drop any previous publish under this key, the way
        // a reconnecting encoder does.
        try await sendCommand(name: "releaseStream", transaction: 2, streamID: 0, arguments: [
            GoProAmf0.null(), GoProAmf0.string(endpoint.streamName),
        ])
        try await sendCommand(name: "FCPublish", transaction: 3, streamID: 0, arguments: [
            GoProAmf0.null(), GoProAmf0.string(endpoint.streamName),
        ])

        try await sendCommand(name: "createStream", transaction: 4, streamID: 0, arguments: [GoProAmf0.null()])
        let created = try await awaitResult(transaction: 4)
        if let id = created.last?.number, id >= 1 {
            publishStreamID = UInt32(id)
        }

        try await sendCommand(
            name: "publish",
            transaction: 5,
            streamID: publishStreamID,
            arguments: [
                GoProAmf0.null(),
                GoProAmf0.string(endpoint.streamName),
                GoProAmf0.string("live"),
            ]
        )

        // The confirmation is useful but must not block the push: some ingests
        // stay quiet, so a silent server is not treated as a failure.
        try await confirmPublish(within: metadataTimer)
        connection.cancelDeadline()
        didPublish = true
    }

    /// Send the `@setDataFrame` metadata a player uses to size its buffer.
    ///
    /// Audio fields are `nil` until something has read them from the stream:
    /// a claim the media does not match is worse than a missing key.
    public func sendMetadata(
        width: Int?,
        height: Int?,
        frameRate: Double?,
        videoBitrate: Double?,
        audioSampleRate: Double?,
        channels: Int?
    ) async throws {
        let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)

        var pairs: [(String, Data)] = [("encoder", GoProAmf0.string("GoProRebuild iOS"))]
        if let width { pairs.append(("width", GoProAmf0.number(Double(width)))) }
        if let height { pairs.append(("height", GoProAmf0.number(Double(height)))) }
        if let frameRate { pairs.append(("framerate", GoProAmf0.number(frameRate))) }
        if let videoBitrate { pairs.append(("videodatarate", GoProAmf0.number(videoBitrate))) }
        pairs.append(("videocodecid", GoProAmf0.number(7)))
        if let audioSampleRate { pairs.append(("audiosamplerate", GoProAmf0.number(audioSampleRate))) }
        if audioSampleRate != nil { pairs.append(("audiosamplesize", GoProAmf0.number(16))) }
        if let channels {
            pairs.append(("stereo", GoProAmf0.boolean(channels > 1)))
            pairs.append(("audiocodecid", GoProAmf0.number(10)))
        }

        var payload = GoProAmf0.string("@setDataFrame")
        payload.append(GoProAmf0.string("onMetaData"))
        payload.append(GoProAmf0.ecmaArray(pairs))

        try await send(chunker.message(
            channel: GoProRtmpChannel.control,
            timestamp: 0,
            type: GoProRtmpMessage.Kind.dataAMF0.rawValue,
            streamID: publishStreamID,
            payload: payload
        ))
    }

    /// One video tag body, produced by `GoProFlvMuxer`.
    public func sendVideo(_ tag: Data, timestampMS: UInt32) async throws {
        let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)
        try await send(chunker.message(
            channel: GoProRtmpChannel.video,
            timestamp: timestampMS,
            type: GoProRtmpMessage.Kind.video.rawValue,
            streamID: publishStreamID,
            payload: tag
        ))
    }

    /// One audio tag body, produced by `GoProFlvMuxer`.
    public func sendAudio(_ tag: Data, timestampMS: UInt32) async throws {
        let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)
        try await send(chunker.message(
            channel: GoProRtmpChannel.audio,
            timestamp: timestampMS,
            type: GoProRtmpMessage.Kind.audio.rawValue,
            streamID: publishStreamID,
            payload: tag
        ))
    }

    /// Read server messages in the background for the life of the session.
    ///
    /// An ingest only ever talks back to acknowledge data, to ping, or to say
    /// the stream ended. Nothing here is needed to send media, but ignoring the
    /// pings gets the connection dropped.
    public func startDraining() {
        guard drainTask == nil else { return }
        drainTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    /// End the session: delete the stream, then close the socket.
    public func close() async {
        drainTask?.cancel()
        drainTask = nil
        guard !isClosed else { return }
        isClosed = true

        if didPublish {
            let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)
            var payload = GoProAmf0.string("deleteStream")
            payload.append(GoProAmf0.number(6))
            payload.append(GoProAmf0.null())
            payload.append(GoProAmf0.number(Double(publishStreamID)))
            let message = chunker.message(
                channel: GoProRtmpChannel.command,
                timestamp: 0,
                type: GoProRtmpMessage.Kind.commandAMF0.rawValue,
                streamID: publishStreamID,
                payload: payload
            )
            try? await send(message)
        }
        connection.close()
    }

    // MARK: - Handshake

    private func handshake() async throws {
        // C0: version 3. C1: time, zero, 1528 random bytes.
        var c1 = Data()
        c1.append(Self.uint32BE(0))
        c1.append(Self.uint32BE(0))
        var generator = SystemRandomNumberGenerator()
        c1.append(contentsOf: (0..<1528).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try await send(Data([0x03]) + c1)

        // S0 + S1 + S2.
        let response = try await readExactly(3073)
        guard response[response.startIndex] == 0x03 else {
            throw GoProRtmpError.handshake("Version \(response[response.startIndex]) is not supported.")
        }
        let s1 = Data(response[(response.startIndex + 1)..<(response.startIndex + 1537)])
        // C2 echoes S1.
        try await send(s1)

        // A server may answer before C2 is even written, so anything read past
        // S2 belongs to the command phase and has to reach the chunk parser.
        if !incoming.isEmpty {
            parser.append(incoming)
            incoming.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Reading

    private func readExactly(_ count: Int) async throws -> Data {
        while incoming.count < count {
            incoming.append(try await readChunkFromConnection())
        }
        let result = Data(incoming.prefix(count))
        incoming.removeFirst(count)
        return result
    }

    private func readChunkFromConnection() async throws -> Data {
        let data = try await connection.read()
        receivedBytes += data.count
        return data
    }

    /// Read until the next message has been reassembled.
    private func nextMessage() async throws -> GoProRtmpMessage {
        while true {
            if let message = parser.nextMessage() {
                handleAcknowledgementIfNeeded()
                return message
            }
            let data = try await connection.read()
            receivedBytes += data.count
            parser.append(data)
            handleAcknowledgementIfNeeded()
        }
    }

    /// Keep the server's window satisfied: it stops talking back if it is owed
    /// an acknowledgement for too long.
    private func handleAcknowledgementIfNeeded() {
        guard acknowledgementWindow > 0, receivedBytes - acknowledgedBytes >= acknowledgementWindow else { return }
        acknowledgedBytes = receivedBytes
        let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)
        let message = chunker.message(
            channel: GoProRtmpChannel.control,
            timestamp: 0,
            type: GoProRtmpMessage.Kind.acknowledgement.rawValue,
            streamID: 0,
            payload: Self.uint32BE(UInt32(receivedBytes))
        )
        Task { [weak self] in
            await self?.sendQuietly(message)
        }
    }

    private static let defaultWindow = 5_000_000

    /// Answer protocol control traffic and remember the server's chunk size.
    ///
    /// Returns `true` when the message was internal to the session and the
    /// caller should not act on it.
    private func handleInternal(_ message: GoProRtmpMessage) -> Bool {
        switch message.kind {
        case .setChunkSize:
            parser.applyChunkSize(from: message)
            return true
        case .windowAcknowledgementSize:
            if message.payload.count >= 4 {
                acknowledgementWindow = Int(Self.readUInt32BE(message.payload, message.payload.startIndex))
            }
            return true
        case .userControl:
            if message.payload.count >= 6 {
                let event = UInt16(message.payload[message.payload.startIndex]) << 8
                    | UInt16(message.payload[message.payload.startIndex + 1])
                // 6 is a ping request; the answer is the same payload as event 7.
                if event == 6 {
                    let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)
                    var payload = Data([0x00, 0x07])
                    payload.append(message.payload.dropFirst(2))
                    let reply = chunker.message(
                        channel: GoProRtmpChannel.control,
                        timestamp: 0,
                        type: GoProRtmpMessage.Kind.userControl.rawValue,
                        streamID: 0,
                        payload: payload
                    )
                    Task { [weak self] in
                        await self?.sendQuietly(reply)
                    }
                }
            }
            return true
        default:
            return false
        }
    }

    /// Watch for the server's verdict on the publish stream.
    private func confirmPublish(within interval: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            guard let message = try await nextMessageOrTimeout(remaining) else { return }
            if handleInternal(message) { continue }
            if let outcome = publishOutcome(from: message) { throw outcome }
            if isPublishAccepted(message) { return }
        }
    }

    /// `nil` when nothing arrived before the timeout.
    private func nextMessageOrTimeout(_ interval: TimeInterval) async throws -> GoProRtmpMessage? {
        while true {
            if let message = parser.nextMessage() {
                handleAcknowledgementIfNeeded()
                return message
            }
            guard let data = try await connection.read(waitingUpTo: interval) else { return nil }
            receivedBytes += data.count
            parser.append(data)
            handleAcknowledgementIfNeeded()
        }
    }

    private func isPublishAccepted(_ message: GoProRtmpMessage) -> Bool {
        guard message.kind == .commandAMF0 else { return false }
        let values = GoProAmf0.decode(message.payload)
        guard let name = values.first?.string, name == "onStatus" else { return false }
        guard let info = values.last, let code = info.property("code")?.string else { return false }
        return code == "NetStream.Publish.Start"
    }

    /// A command failure, whether from `_error` or from `onStatus`.
    private func publishOutcome(from message: GoProRtmpMessage) -> GoProRtmpError? {
        guard message.kind == .commandAMF0 else { return nil }
        let values = GoProAmf0.decode(message.payload)
        guard let name = values.first?.string else { return nil }

        let info = values.last
        let code = info?.property("code")?.string ?? ""
        let description = info?.property("description")?.string ?? ""

        if name == "onStatus" {
            let event = GoProRtmpStatusEvent(code: code, description: description)
            onStatus?(event)
            return event.isFailure ? .refused(code: code, description: description) : nil
        }
        if name == "_error" {
            onStatus?(GoProRtmpStatusEvent(code: code.isEmpty ? "_error" : code, description: description))
            return .refused(code: code, description: description)
        }
        return nil
    }

    /// Wait for the `_result` or `_error` of one command transaction.
    private func awaitResult(transaction: Double) async throws -> [GoProAmf0.Value] {
        while true {
            let message = try await nextMessage()
            if handleInternal(message) { continue }

            guard message.kind == .commandAMF0 else { continue }
            let values = GoProAmf0.decode(message.payload)
            guard let name = values.first?.string else { continue }
            guard values.count > 1, let replyTransaction = values[1].number else { continue }
            guard replyTransaction == transaction else {
                onStatus?(GoProRtmpStatusEvent(
                    code: name,
                    description: values.last?.property("description")?.string ?? ""
                ))
                continue
            }

            if name == "_error" {
                let description = values.last?.property("description")?.string ?? ""
                throw GoProRtmpError.command(description.isEmpty ? "remote error" : description)
            }
            return values
        }
    }

    private func drain() async {
        while !Task.isCancelled {
            do {
                let message = try await nextMessage()
                if handleInternal(message) { continue }
                // `publishOutcome` reports the status itself; a non-nil result
                // means the server said the stream is no longer welcome.
                if publishOutcome(from: message) != nil { return }
            } catch {
                return
            }
        }
    }

    // MARK: - Writing

    private func send(_ data: Data) async throws {
        try await writer.write(data)
    }

    /// Best-effort write for replies nobody is waiting on.
    private func sendQuietly(_ data: Data) async {
        try? await writer.write(data)
    }

    private func sendCommand(
        name: String,
        transaction: Double,
        streamID: UInt32,
        arguments: [Data]
    ) async throws {
        var payload = GoProAmf0.string(name)
        payload.append(GoProAmf0.number(transaction))
        for argument in arguments {
            payload.append(argument)
        }
        let chunker = GoProRtmpMessageWriter(chunkSize: chunkSize)
        try await send(chunker.message(
            channel: GoProRtmpChannel.command,
            timestamp: 0,
            type: GoProRtmpMessage.Kind.commandAMF0.rawValue,
            streamID: streamID,
            payload: payload
        ))
    }

    private static let flashVersion = "FMLE/3.0 (compatible; FMSc/1.0)"

    static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private static func readUInt32BE(_ data: Data, _ index: Data.Index) -> UInt32 {
        (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
    }
}
