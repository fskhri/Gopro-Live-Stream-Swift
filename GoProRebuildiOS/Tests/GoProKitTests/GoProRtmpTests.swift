import XCTest
@testable import GoProKit

// MARK: - Fake connection

/// A connection whose bytes are all scripted, so the RTMP session can be
/// exercised without a server.
final class FakeRtmpConnection: GoProRtmpConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming = Data()
    private var written = Data()
    private var closedFlag = false
    private var armedDeadlines = 0
    private var cancelledDeadlines = 0

    enum FakeError: Error { case nothingToRead }

    func queue(_ data: Data) {
        lock.lock()
        incoming.append(data)
        lock.unlock()
    }

    func write(_ data: Data) async throws {
        lock.lock()
        written.append(data)
        lock.unlock()
    }

    func read() async throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !incoming.isEmpty else { throw FakeError.nothingToRead }
        let data = incoming
        incoming = Data()
        return data
    }

    func read(waitingUpTo interval: TimeInterval) async throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !incoming.isEmpty else { return nil }
        let data = incoming
        incoming = Data()
        return data
    }

    func close() {
        lock.lock()
        closedFlag = true
        lock.unlock()
    }

    func armDeadline(after interval: TimeInterval) {
        lock.lock()
        armedDeadlines += 1
        lock.unlock()
    }

    func cancelDeadline() {
        lock.lock()
        cancelledDeadlines += 1
        lock.unlock()
    }

    var writtenBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedFlag
    }

    var deadlineCounts: (armed: Int, cancelled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (armedDeadlines, cancelledDeadlines)
    }
}

// MARK: - Helpers

private enum RtmpTestData {
    /// S0 + S1 + S2, the answer to a handshake.
    static func serverHandshake() -> Data {
        var data = Data([0x03])
        data.append(Data(repeating: 0x11, count: 1536))
        data.append(Data(repeating: 0x22, count: 1536))
        return data
    }

    static func message(
        channel: UInt8,
        type: GoProRtmpMessage.Kind,
        streamID: UInt32 = 0,
        timestamp: UInt32 = 0,
        payload: Data
    ) -> Data {
        GoProRtmpMessageWriter(chunkSize: 4096).message(
            channel: channel,
            timestamp: timestamp,
            type: type.rawValue,
            streamID: streamID,
            payload: payload
        )
    }

    /// A `_result` for one command.
    static func result(transaction: Double, values: [Data] = [GoProAmf0.null()]) -> Data {
        var payload = GoProAmf0.string("_result")
        payload.append(GoProAmf0.number(transaction))
        payload.append(GoProAmf0.null())
        for value in values { payload.append(value) }
        return message(channel: GoProRtmpChannel.command, type: .commandAMF0, payload: payload)
    }

    static func onStatus(code: String, description: String = "") -> Data {
        var payload = GoProAmf0.string("onStatus")
        payload.append(GoProAmf0.number(0))
        payload.append(GoProAmf0.null())
        payload.append(GoProAmf0.object([
            ("level", GoProAmf0.string("status")),
            ("code", GoProAmf0.string(code)),
            ("description", GoProAmf0.string(description)),
        ]))
        return message(channel: GoProRtmpChannel.command, type: .commandAMF0, payload: payload)
    }

    /// Every command the client wrote, after the handshake preamble.
    static func commands(in written: Data) -> [(name: String, transaction: Double, streamID: UInt32, payload: Data)] {
        let preamble = 1 + 1536 + 1536
        guard written.count > preamble else { return [] }

        let parser = GoProRtmpMessageParser()
        parser.append(Data(written.dropFirst(preamble)))

        var commands: [(String, Double, UInt32, Data)] = []
        while let message = parser.nextMessage() {
            parser.applyChunkSize(from: message)
            guard message.kind == .commandAMF0 else { continue }
            let values = GoProAmf0.decode(message.payload)
            guard let name = values.first?.string, values.count > 1, let transaction = values[1].number else { continue }
            commands.append((name, transaction, message.streamID, message.payload))
        }
        return commands
    }
}

// MARK: - Endpoint

final class GoProRtmpEndpointTests: XCTestCase {
    func testSplitsTikTokPushURL() throws {
        let endpoint = try XCTUnwrap(GoProRtmpEndpoint(
            url: "rtmp://push-rtmp-l1-id01.tiktok.com/live/abc123?expire=1700000000&sign=x%2By"
        ))

        XCTAssertEqual(endpoint.host, "push-rtmp-l1-id01.tiktok.com")
        XCTAssertEqual(endpoint.port, 1935)
        XCTAssertEqual(endpoint.app, "live")
        XCTAssertEqual(endpoint.streamName, "abc123?expire=1700000000&sign=x%2By")
        XCTAssertEqual(endpoint.tcUrl, "rtmp://push-rtmp-l1-id01.tiktok.com/live")
        XCTAssertFalse(endpoint.usesTLS)
    }

    func testKeepsAnExplicitPortInTheTcUrl() throws {
        let endpoint = try XCTUnwrap(GoProRtmpEndpoint(url: "rtmp://example.com:1936/live/key"))

        XCTAssertEqual(endpoint.port, 1936)
        XCTAssertEqual(endpoint.tcUrl, "rtmp://example.com:1936/live")
    }

    func testRTMPSUsesTheTLSDefaultPort() throws {
        let endpoint = try XCTUnwrap(GoProRtmpEndpoint(url: "rtmps://example.com/live/key"))

        XCTAssertTrue(endpoint.usesTLS)
        XCTAssertEqual(endpoint.port, 443)
    }

    func testKeepsAnAppWithSeveralSegments() throws {
        let endpoint = try XCTUnwrap(GoProRtmpEndpoint(url: "rtmp://example.com/live/v2/key"))

        XCTAssertEqual(endpoint.app, "live/v2")
        XCTAssertEqual(endpoint.streamName, "key")
        XCTAssertEqual(endpoint.tcUrl, "rtmp://example.com/live/v2")
    }

    func testRejectsEverythingElse() {
        XCTAssertNil(GoProRtmpEndpoint(url: "https://example.com/live/key"))
        XCTAssertNil(GoProRtmpEndpoint(url: "rtmp://example.com/"))
        XCTAssertNil(GoProRtmpEndpoint(url: "not a url"))
    }
}

// MARK: - FLV muxer

final class GoProFlvMuxerTests: XCTestCase {
    private let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xAB])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])

    func testAudioHeaderMarksAACAndTheChannelCount() {
        XCTAssertEqual(GoProFlvMuxer.audioHeader(channels: 1), 0xAE)
        XCTAssertEqual(GoProFlvMuxer.audioHeader(channels: 2), 0xAF)
    }

    func testAudioSequenceHeaderCarriesTheConfig() {
        let tag = GoProFlvMuxer.audioSequenceHeader(config: Data([0x11, 0x88]), channels: 1)

        XCTAssertEqual(tag, Data([0xAE, 0x00, 0x11, 0x88]))
    }

    func testAudioTagCarriesTheRawFrame() {
        let frame = GoProAudioFrame(
            aacData: Data([0x01, 0x02, 0x03]),
            presentationTime: 1,
            audioSpecificConfig: Data([0x11, 0x88])
        )

        XCTAssertEqual(GoProFlvMuxer.audioTag(frame, channels: 1), Data([0xAE, 0x01, 0x01, 0x02, 0x03]))
    }

    func testDecoderConfigurationRecordLayout() throws {
        let record = try XCTUnwrap(GoProFlvMuxer.avcDecoderConfigurationRecord(sps: sps, pps: pps))

        XCTAssertEqual(record, Data([
            0x01,  // configuration version
            0x42,  // profile, from SPS byte 1
            0xC0,  // compatibility
            0x1E,  // level
            0xFF,  // 4-byte NAL length prefixes
            0xE1,  // one SPS
            0x00, 0x05, 0x67, 0x42, 0xC0, 0x1E, 0xAB,
            0x01,  // one PPS
            0x00, 0x04, 0x68, 0xCE, 0x3C, 0x80,
        ]))
    }

    func testDecoderConfigurationRecordRejectsForeignParameterSets() {
        XCTAssertNil(GoProFlvMuxer.avcDecoderConfigurationRecord(sps: Data([0x68, 0x00]), pps: pps))
        XCTAssertNil(GoProFlvMuxer.avcDecoderConfigurationRecord(sps: sps, pps: Data([0x67, 0x00])))
        XCTAssertNil(GoProFlvMuxer.avcDecoderConfigurationRecord(sps: Data([0x67]), pps: pps))
    }

    func testVideoSequenceHeaderIsAKeyFrameAVCHeader() throws {
        let tag = try XCTUnwrap(GoProFlvMuxer.videoSequenceHeader(sps: sps, pps: pps))

        XCTAssertEqual(Array(tag.prefix(5)), [0x17, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(tag.count, 5 + 20)
    }

    func testVideoTagUsesTheFrameType() {
        let key = GoProFlvMuxer.videoTag(GoProAccessUnit(
            avccData: Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01]),
            isKeyFrame: true,
            presentationTime: 0,
            decodeTime: 0
        ))
        let inter = GoProFlvMuxer.videoTag(GoProAccessUnit(
            avccData: Data([0x00, 0x00, 0x00, 0x02, 0x41, 0x01]),
            isKeyFrame: false,
            presentationTime: 0,
            decodeTime: 0
        ))

        XCTAssertEqual(key[0], 0x17)
        XCTAssertEqual(key[1], 0x01)
        XCTAssertEqual(Array(key[2...4]), [0x00, 0x00, 0x00])
        XCTAssertEqual(inter[0], 0x27)
        XCTAssertEqual(key.count, 5 + 6)
    }
}

// MARK: - AMF0

final class GoProAmf0Tests: XCTestCase {
    func testEncodesPrimitives() {
        XCTAssertEqual(GoProAmf0.string("a"), Data([0x02, 0x00, 0x01, 0x61]))
        XCTAssertEqual(GoProAmf0.boolean(true), Data([0x01, 0x01]))
        XCTAssertEqual(GoProAmf0.null(), Data([0x05]))
        XCTAssertEqual(GoProAmf0.number(1).count, 9)
        XCTAssertEqual(GoProAmf0.number(1)[0], 0x00)
    }

    func testDecodesACommandBack() {
        var payload = GoProAmf0.string("publish")
        payload.append(GoProAmf0.number(5))
        payload.append(GoProAmf0.null())
        payload.append(GoProAmf0.string("key?sign=abc"))
        payload.append(GoProAmf0.string("live"))

        let values = GoProAmf0.decode(payload)

        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0].string, "publish")
        XCTAssertEqual(values[1].number, 5)
        XCTAssertEqual(values[2], .null)
        XCTAssertEqual(values[3].string, "key?sign=abc")
        XCTAssertEqual(values[4].string, "live")
    }

    func testObjectRoundTrip() {
        let object = GoProAmf0.object([
            ("app", GoProAmf0.string("live")),
            ("capabilities", GoProAmf0.number(15)),
            ("fpad", GoProAmf0.boolean(false)),
        ])

        let decoded = GoProAmf0.decode(object)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].property("app")?.string, "live")
        XCTAssertEqual(decoded[0].property("capabilities")?.number, 15)
        XCTAssertEqual(decoded[0].property("fpad"), .boolean(false))
        XCTAssertNil(decoded[0].property("missing"))
    }

    func testECMAArrayRoundTrip() {
        let array = GoProAmf0.ecmaArray([
            ("width", GoProAmf0.number(1920)),
            ("height", GoProAmf0.number(1080)),
        ])

        let decoded = GoProAmf0.decode(array)

        XCTAssertEqual(decoded[0].property("width")?.number, 1920)
        XCTAssertEqual(decoded[0].property("height")?.number, 1080)
    }

    func testNestedObjectRoundTrip() {
        let object = GoProAmf0.object([
            ("info", GoProAmf0.object([("code", GoProAmf0.string("NetStream.Publish.Start"))])),
        ])

        let decoded = GoProAmf0.decode(object)

        XCTAssertEqual(decoded[0].property("info")?.property("code")?.string, "NetStream.Publish.Start")
    }

    func testDecodeStopsOnTruncatedInput() {
        let truncated = Data([0x02, 0x00, 0x10, 0x61])

        XCTAssertTrue(GoProAmf0.decode(truncated).isEmpty)
    }
}

// MARK: - Chunk framing

final class GoProRtmpChunkTests: XCTestCase {
    func testWriterEmitsAFullHeaderForTheFirstChunk() {
        let writer = GoProRtmpMessageWriter(chunkSize: 4096)
        let data = writer.message(
            channel: GoProRtmpChannel.command,
            timestamp: 0x000102,
            type: GoProRtmpMessage.Kind.commandAMF0.rawValue,
            streamID: 0x00000007,
            payload: Data([0xAA, 0xBB])
        )

        XCTAssertEqual(Array(data.prefix(13)), [
            0x03,  // format 0, channel 3
            0x00, 0x01, 0x02,  // timestamp
            0x00, 0x00, 0x02,  // length
            0x14,  // 20: AMF0 command
            0x07, 0x00, 0x00, 0x00,  // stream id, little endian
            0xAA,
        ])
        XCTAssertEqual(data.count, 14)
    }

    /// A parser told the same chunk size the writer used, the way a real reader
    /// learns it from the Set Chunk Size message.
    private func parser(chunkSize: Int) -> GoProRtmpMessageParser {
        let parser = GoProRtmpMessageParser()
        parser.append(GoProRtmpMessageWriter(chunkSize: chunkSize).setChunkSize(chunkSize))
        if let announcement = parser.nextMessage() {
            parser.applyChunkSize(from: announcement)
        }
        return parser
    }

    func testLargePayloadRoundTripsThroughContinuationChunks() throws {
        let payload = Data((0..<10_000).map { UInt8($0 % 251) })
        let written = GoProRtmpMessageWriter(chunkSize: 4096).message(
            channel: GoProRtmpChannel.video,
            timestamp: 33,
            type: GoProRtmpMessage.Kind.video.rawValue,
            streamID: 1,
            payload: payload
        )

        let parser = parser(chunkSize: 4096)
        parser.append(written)
        let message = try XCTUnwrap(parser.nextMessage())

        XCTAssertEqual(message.payload, payload)
        XCTAssertEqual(message.timestamp, 33)
        XCTAssertEqual(message.streamID, 1)
        XCTAssertEqual(message.kind, .video)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testExtendedTimestampRoundTrips() throws {
        let payload = Data(repeating: 0x5A, count: 9000)
        let timestamp: UInt32 = 0x0100_0000
        let written = GoProRtmpMessageWriter(chunkSize: 4096).message(
            channel: GoProRtmpChannel.video,
            timestamp: timestamp,
            type: GoProRtmpMessage.Kind.video.rawValue,
            streamID: 1,
            payload: payload
        )

        let parser = parser(chunkSize: 4096)
        parser.append(written)
        let message = try XCTUnwrap(parser.nextMessage())

        XCTAssertEqual(message.timestamp, timestamp)
        XCTAssertEqual(message.payload, payload)
    }

    func testDeltaTimestampsAccumulate() throws {
        // Two format-1 chunks on the same channel: 100 ms then 50 ms more.
        let first = Data([0x43, 0x00, 0x00, 0x64, 0x00, 0x00, 0x01, 0x09, 0x0A])
        let second = Data([0x43, 0x00, 0x00, 0x32, 0x00, 0x00, 0x01, 0x09, 0x0B])

        let parser = GoProRtmpMessageParser()
        parser.append(first)
        XCTAssertEqual(try XCTUnwrap(parser.nextMessage()).timestamp, 100)
        parser.append(second)
        XCTAssertEqual(try XCTUnwrap(parser.nextMessage()).timestamp, 150)
    }

    func testParserWaitsForTheRestOfAChunk() throws {
        let payload = Data(repeating: 0x7E, count: 300)
        let written = GoProRtmpMessageWriter(chunkSize: 128).message(
            channel: GoProRtmpChannel.audio,
            timestamp: 5,
            type: GoProRtmpMessage.Kind.audio.rawValue,
            streamID: 1,
            payload: payload
        )

        let parser = parser(chunkSize: 128)
        parser.append(Data(written.prefix(100)))
        XCTAssertNil(parser.nextMessage())

        parser.append(Data(written.dropFirst(100)))
        let message = try XCTUnwrap(parser.nextMessage())
        XCTAssertEqual(message.payload, payload)
    }

    func testSetChunkSizeChangesTheIncomingCeiling() throws {
        let peer = GoProRtmpMessageWriter(chunkSize: 4096)
        let announcement = peer.setChunkSize(4096)
        let payload = Data(repeating: 0x33, count: 5000)
        let big = peer.message(
            channel: GoProRtmpChannel.audio,
            timestamp: 9,
            type: GoProRtmpMessage.Kind.audio.rawValue,
            streamID: 1,
            payload: payload
        )

        let parser = GoProRtmpMessageParser()
        XCTAssertEqual(parser.chunkSize, 128)

        parser.append(announcement)
        let control = try XCTUnwrap(parser.nextMessage())
        XCTAssertEqual(control.kind, .setChunkSize)
        parser.applyChunkSize(from: control)
        XCTAssertEqual(parser.chunkSize, 4096)

        parser.append(big)
        XCTAssertEqual(try XCTUnwrap(parser.nextMessage()).payload, payload)
    }
}

// MARK: - Client

final class GoProRtmpClientTests: XCTestCase {
    private let endpoint = GoProRtmpEndpoint(url: "rtmp://push.tiktok.com/live/key123?sign=abc")!

    func testPublishSendsTheWholeCommandSequence() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4, values: [GoProAmf0.number(7)]))
        server.append(RtmpTestData.onStatus(code: "NetStream.Publish.Start"))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        try await client.publish(to: endpoint)

        let commands = RtmpTestData.commands(in: connection.writtenBytes)
        XCTAssertEqual(commands.map(\.name), ["connect", "releaseStream", "FCPublish", "createStream", "publish"])
        XCTAssertEqual(commands.map(\.transaction), [1, 2, 3, 4, 5])

        // `publish` rides on the stream id `createStream` handed back, not on 1.
        XCTAssertEqual(commands.last?.streamID, 7)

        let connect = GoProAmf0.decode(commands[0].payload)
        XCTAssertEqual(connect[0].string, "connect")
        XCTAssertEqual(connect[2].property("app")?.string, "live")
        XCTAssertEqual(connect[2].property("tcUrl")?.string, "rtmp://push.tiktok.com/live")
        XCTAssertEqual(connect[2].property("flashVer")?.string, "FMLE/3.0 (compatible; FMSc/1.0)")

        let publish = GoProAmf0.decode(commands[4].payload)
        XCTAssertEqual(publish[3].string, "key123?sign=abc")
        XCTAssertEqual(publish[4].string, "live")

        // The setup deadline must be dropped once the server accepts.
        XCTAssertEqual(connection.deadlineCounts.armed, 1)
        XCTAssertEqual(connection.deadlineCounts.cancelled, 1)
    }

    func testPublishReportsTheStatusToTheCaller() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4))
        server.append(RtmpTestData.onStatus(code: "NetStream.Publish.Start"))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        let collected = StatusCollector()
        client.onStatus = { collected.append($0) }

        try await client.publish(to: endpoint)

        XCTAssertEqual(collected.events.map(\.code), ["NetStream.Publish.Start"])
    }

    func testPublishThrowsWhenTheServerRejectsTheKey() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4))
        server.append(RtmpTestData.onStatus(
            code: "NetStream.Publish.BadName",
            description: "Stream already publishing."
        ))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)

        do {
            try await client.publish(to: endpoint)
            XCTFail("expected a refusal")
        } catch let error as GoProRtmpError {
            XCTAssertEqual(error, .refused(code: "NetStream.Publish.BadName", description: "Stream already publishing."))
        }
    }

    func testPublishThrowsWhenTheServerErrorsTheCommand() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        var payload = GoProAmf0.string("_error")
        payload.append(GoProAmf0.number(1))
        payload.append(GoProAmf0.null())
        payload.append(GoProAmf0.object([("description", GoProAmf0.string("bad app"))]))
        server.append(RtmpTestData.message(channel: GoProRtmpChannel.command, type: .commandAMF0, payload: payload))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)

        do {
            try await client.publish(to: endpoint)
            XCTFail("expected a command error")
        } catch let error as GoProRtmpError {
            XCTAssertEqual(error, .command("bad app"))
        }
    }

    func testPublishProceedsWhenTheServerStaysQuiet() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        try await client.publish(to: endpoint, metadataTimer: 0.05)

        XCTAssertEqual(RtmpTestData.commands(in: connection.writtenBytes).last?.name, "publish")
    }

    func testHandshakeEchoesTheServerBytesAndKeepsTheLeftovers() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        // The result arrives in the same read as the handshake.
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        try await client.publish(to: endpoint, metadataTimer: 0.05)

        let written = connection.writtenBytes
        XCTAssertGreaterThan(written.count, 3073)
        // C2 is S1, the middle 1536 bytes of the answer.
        let c2 = Data(written[1537..<3073])
        XCTAssertEqual(c2, Data(repeating: 0x11, count: 1536))
    }

    func testMediaTagsGoOutOnTheirOwnChannels() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4))
        server.append(RtmpTestData.onStatus(code: "NetStream.Publish.Start"))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        try await client.publish(to: endpoint)
        try await client.sendVideo(Data([0x17, 0x01, 0x00, 0x00, 0x00, 0xAA]), timestampMS: 1000)
        try await client.sendAudio(Data([0xAE, 0x01, 0xBB]), timestampMS: 1010)

        let written = connection.writtenBytes
        let parser = GoProRtmpMessageParser()
        parser.append(Data(written.dropFirst(3073)))

        var media: [(UInt8, GoProRtmpMessage)] = []
        while let message = parser.nextMessage() {
            parser.applyChunkSize(from: message)
            switch message.kind {
            case .video, .audio: media.append((message.type, message))
            default: continue
            }
        }

        XCTAssertEqual(media.count, 2)
        XCTAssertEqual(media[0].1.kind, .video)
        XCTAssertEqual(media[0].1.timestamp, 1000)
        XCTAssertEqual(media[0].1.payload, Data([0x17, 0x01, 0x00, 0x00, 0x00, 0xAA]))
        XCTAssertEqual(media[1].1.kind, .audio)
        XCTAssertEqual(media[1].1.timestamp, 1010)
        XCTAssertEqual(media[1].1.payload, Data([0xAE, 0x01, 0xBB]))
    }

    func testMetadataCarriesTheCodecIds() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        try await client.publish(to: endpoint, metadataTimer: 0.05)
        try await client.sendMetadata(
            width: 1920,
            height: 1080,
            frameRate: 59.94,
            videoBitrate: 8000,
            audioSampleRate: 48000,
            channels: 1
        )

        let parser = GoProRtmpMessageParser()
        parser.append(Data(connection.writtenBytes.dropFirst(3073)))
        var metadata: GoProRtmpMessage?
        while let message = parser.nextMessage() {
            parser.applyChunkSize(from: message)
            if message.kind == .dataAMF0 { metadata = message }
        }

        let values = GoProAmf0.decode(try XCTUnwrap(metadata).payload)
        XCTAssertEqual(values[0].string, "@setDataFrame")
        XCTAssertEqual(values[1].string, "onMetaData")
        XCTAssertEqual(values[2].property("width")?.number, 1920)
        XCTAssertEqual(values[2].property("height")?.number, 1080)
        XCTAssertEqual(values[2].property("videocodecid")?.number, 7)
        XCTAssertEqual(values[2].property("audiocodecid")?.number, 10)
        XCTAssertEqual(values[2].property("stereo"), .boolean(false))
    }

    func testCloseDeletesTheStreamAndClosesTheConnection() async throws {
        let connection = FakeRtmpConnection()
        var server = RtmpTestData.serverHandshake()
        server.append(RtmpTestData.result(transaction: 1))
        server.append(RtmpTestData.result(transaction: 4, values: [GoProAmf0.number(3)]))
        connection.queue(server)

        let client = GoProRtmpClient(connection: connection)
        try await client.publish(to: endpoint, metadataTimer: 0.05)
        await client.close()

        let commands = RtmpTestData.commands(in: connection.writtenBytes)
        XCTAssertEqual(commands.last?.name, "deleteStream")
        XCTAssertTrue(connection.isClosed)

        let delete = GoProAmf0.decode(try XCTUnwrap(commands.last).payload)
        XCTAssertEqual(delete[3].number, 3)
    }
}

/// Collects status events from a `@Sendable` handler.
private final class StatusCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GoProRtmpStatusEvent] = []

    func append(_ event: GoProRtmpStatusEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [GoProRtmpStatusEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
