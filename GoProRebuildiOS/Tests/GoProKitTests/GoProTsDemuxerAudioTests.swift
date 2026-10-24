import XCTest
@testable import GoProKit

// MARK: - Audio stream builder

/// Builds a PAT/PMT pair plus AAC PES packets, mirroring the shape the camera
/// sends: H.264 on one PID and `stream_type 0x0F` ADTS audio on another.
private enum AudioStreamBuilder {
    static let pmtPID = 0x1000
    static let videoPID = 0x100
    static let audioPID = 0x101

    static func tsPacket(pid: Int, payloadUnitStart: Bool, continuity: UInt8, payload: Data) -> Data {
        let payloadLimit = 184
        precondition(payload.count <= payloadLimit)

        var packet = Data(capacity: 188)
        packet.append(0x47)
        packet.append(UInt8((payloadUnitStart ? 0x40 : 0) | ((pid >> 8) & 0x1F)))
        packet.append(UInt8(pid & 0xFF))

        if payload.count == payloadLimit {
            packet.append(UInt8(0x10 | (continuity & 0x0F)))
            packet.append(payload)
        } else {
            packet.append(UInt8(0x30 | (continuity & 0x0F)))
            let adaptationLength = 183 - payload.count
            packet.append(UInt8(adaptationLength))
            if adaptationLength > 0 {
                packet.append(0x00)  // adaptation flags, none set
                packet.append(Data(repeating: 0xFF, count: adaptationLength - 1))
            }
            packet.append(payload)
        }
        return packet
    }

    static func pat() -> Data {
        var section = Data([0x00, 0xB0, 0x0D])
        section.append(contentsOf: [0x00, 0x01])
        section.append(0xC1)
        section.append(contentsOf: [0x00, 0x00])
        section.append(contentsOf: [0x00, 0x01])
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        section.append(contentsOf: [0, 0, 0, 0])
        return Data([0x00]) + section
    }

    /// Video plus audio, or video plus the GoPro private stream.
    static func pmt(audio: Bool) -> Data {
        let streamCount = 2
        let sectionLength = 9 + (streamCount * 5) + 4

        var section = Data([0x02, 0xB0 | UInt8((sectionLength >> 8) & 0x0F), UInt8(sectionLength & 0xFF)])
        section.append(contentsOf: [0x00, 0x01])
        section.append(0xC1)
        section.append(contentsOf: [0x00, 0x00])
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])

        section.append(GoProPreviewConfiguration.h264StreamType)
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])

        let pid = audio ? audioPID : 0x200
        section.append(audio ? GoProPreviewConfiguration.aacStreamType : GoProPreviewConfiguration.privateStreamType)
        section.append(UInt8(0xE0 | ((pid >> 8) & 0x1F)))
        section.append(UInt8(pid & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])

        section.append(contentsOf: [0, 0, 0, 0])
        return Data([0x00]) + section
    }

    /// An ADTS frame: 7-byte header plus payload.
    ///
    /// `frameLength` is computed from the payload, so the header always
    /// describes a frame the parser can trust.
    static func adtsFrame(payload: Data, sampleRateIndex: Int = 3, channels: Int = 1) -> Data {
        let frameLength = 7 + payload.count
        // Byte 1: sync tail, ID 0, layer 0, protection_absent 1 (no CRC).
        // Byte 2: profile 1 (AAC LC), sample-rate index, channels high bit.
        let profileField = 1
        let byte2 = ((profileField & 0x03) << 6) | ((sampleRateIndex & 0x0F) << 2) | ((channels >> 2) & 0x01)
        let byte3 = ((channels & 0x03) << 6) | ((frameLength >> 11) & 0x03)
        let byte4 = (frameLength >> 3) & 0xFF
        let byte5 = ((frameLength & 0x07) << 5) | 0x1F

        var header = Data([0xFF, 0xF1, UInt8(byte2), UInt8(byte3), UInt8(byte4), UInt8(byte5), 0xFC])
        header.append(payload)
        return header
    }

    /// One audio PES packet. `pts` nil omits the timestamp, as the camera does
    /// on the frames where it only sends a decode timestamp.
    static func audioPES(es: Data, pts: Double?) -> Data {
        var pes = Data([0x00, 0x00, 0x01, 0xC0])
        let headerDataLength = pts == nil ? 0 : 5
        let pesLength = 3 + headerDataLength + es.count
        pes.append(UInt8((pesLength >> 8) & 0xFF))
        pes.append(UInt8(pesLength & 0xFF))
        pes.append(contentsOf: [0x80, pts == nil ? 0x00 : 0x80, UInt8(headerDataLength)])
        if let pts { pes.append(timestamp(pts)) }
        pes.append(es)
        return pes
    }

    static func timestamp(_ seconds: Double) -> Data {
        let ticks = UInt64((seconds * 90_000).rounded())
        return Data([
            0x21 | UInt8((ticks >> 29) & 0x0E),
            UInt8((ticks >> 22) & 0xFF),
            0x01 | UInt8((ticks >> 14) & 0xFE),
            UInt8((ticks >> 7) & 0xFF),
            0x01 | UInt8((ticks << 1) & 0xFE),
        ])
    }

    /// TS packets for one PES packet, continuity starting at `continuity`.
    static func packets(_ pes: Data, continuity: UInt8) -> [Data] {
        var packets: [Data] = []
        var index = pes.startIndex
        var counter = continuity
        var first = true

        while index < pes.endIndex {
            let end = min(index + 184, pes.endIndex)
            packets.append(tsPacket(
                pid: audioPID,
                payloadUnitStart: first,
                continuity: counter,
                payload: Data(pes[index..<end])
            ))
            index = end
            counter &+= 1
            first = false
        }
        return packets
    }

    static func header() -> Data {
        var bytes = Data()
        bytes.append(tsPacket(pid: 0, payloadUnitStart: true, continuity: 0, payload: pat()))
        bytes.append(tsPacket(pid: pmtPID, payloadUnitStart: true, continuity: 0, payload: pmt(audio: true)))
        return bytes
    }
}

// MARK: - Tests

final class GoProTsDemuxerAudioTests: XCTestCase {
    private let aacPayload = Data([0x21, 0x1A, 0xB6, 0x6C, 0x00, 0x40])
    private let secondPayload = Data([0x11, 0x22, 0x33, 0x44])

    func testPMTAssignsTheAudioPID() {
        let demuxer = GoProTsDemuxer()
        _ = demuxer.feed(AudioStreamBuilder.header())

        XCTAssertEqual(demuxer.videoPID, AudioStreamBuilder.videoPID)
        XCTAssertEqual(demuxer.audioPID, AudioStreamBuilder.audioPID)
    }

    func testPMTWithoutAnAACStreamLeavesTheAudioPIDEmpty() {
        let demuxer = GoProTsDemuxer()
        var bytes = Data()
        bytes.append(AudioStreamBuilder.tsPacket(pid: 0, payloadUnitStart: true, continuity: 0, payload: AudioStreamBuilder.pat()))
        bytes.append(AudioStreamBuilder.tsPacket(
            pid: AudioStreamBuilder.pmtPID,
            payloadUnitStart: true,
            continuity: 0,
            payload: AudioStreamBuilder.pmt(audio: false)
        ))

        _ = demuxer.feed(bytes)
        XCTAssertNil(demuxer.audioPID)
    }

    func testAudioFrameStripsTheADTSHeaderAndBuildsTheConfig() {
        let demuxer = GoProTsDemuxer()
        var bytes = AudioStreamBuilder.header()
        for packet in AudioStreamBuilder.packets(
            AudioStreamBuilder.audioPES(
                es: AudioStreamBuilder.adtsFrame(payload: aacPayload),
                pts: 2.0
            ),
            continuity: 0
        ) {
            bytes.append(packet)
        }

        _ = demuxer.feed(bytes)
        let events = demuxer.flush()

        let frames = events.compactMap { event -> GoProAudioFrame? in
            guard case .audioFrame(let frame) = event else { return nil }
            return frame
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.aacData, aacPayload, "the ADTS header must not survive")
        // profile 2 (AAC LC), 48 kHz (index 3), mono (1).
        XCTAssertEqual(frames.first?.audioSpecificConfig, Data([0x11, 0x88]))
        XCTAssertEqual(frames.first?.presentationTime ?? 0, 2.0, accuracy: 1e-6)
        XCTAssertEqual(demuxer.statistics.audioPackets, 1)
    }

    func testTwoFramesInOnePESAdvanceByOneFrameOfSamples() {
        let demuxer = GoProTsDemuxer()
        let es = AudioStreamBuilder.adtsFrame(payload: aacPayload) + AudioStreamBuilder.adtsFrame(payload: secondPayload)

        var bytes = AudioStreamBuilder.header()
        for packet in AudioStreamBuilder.packets(AudioStreamBuilder.audioPES(es: es, pts: 4.0), continuity: 0) {
            bytes.append(packet)
        }

        _ = demuxer.feed(bytes)
        let frames = demuxer.flush().compactMap { event -> GoProAudioFrame? in
            guard case .audioFrame(let frame) = event else { return nil }
            return frame
        }

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].aacData, aacPayload)
        XCTAssertEqual(frames[1].aacData, secondPayload)
        // 1024 samples at 48 kHz.
        XCTAssertEqual(frames[1].presentationTime - frames[0].presentationTime, 1024.0 / 48_000.0, accuracy: 1e-6)
    }

    func testAnIncompleteFrameIsCarriedIntoTheNextPES() {
        let demuxer = GoProTsDemuxer()
        let whole = AudioStreamBuilder.adtsFrame(payload: aacPayload)
        let split = whole.count / 2

        var bytes = AudioStreamBuilder.header()
        for packet in AudioStreamBuilder.packets(
            AudioStreamBuilder.audioPES(es: Data(whole.prefix(split)), pts: 1.0),
            continuity: 0
        ) {
            bytes.append(packet)
        }
        for packet in AudioStreamBuilder.packets(
            AudioStreamBuilder.audioPES(es: Data(whole.suffix(from: split)), pts: 1.021333),
            continuity: UInt8(1 + split / 184)
        ) {
            bytes.append(packet)
        }

        _ = demuxer.feed(bytes)
        let frames = demuxer.flush().compactMap { event -> GoProAudioFrame? in
            guard case .audioFrame(let frame) = event else { return nil }
            return frame
        }

        XCTAssertEqual(frames.count, 1, "the split frame must be reassembled exactly once")
        XCTAssertEqual(frames.first?.aacData, aacPayload)
    }

    func testSyncSearchSkipsBytesThatAreNotAFrameStart() {
        let demuxer = GoProTsDemuxer()
        var es = Data([0xAA, 0xBB, 0xFF, 0x00])
        es.append(AudioStreamBuilder.adtsFrame(payload: aacPayload))

        var bytes = AudioStreamBuilder.header()
        for packet in AudioStreamBuilder.packets(AudioStreamBuilder.audioPES(es: es, pts: 0.5), continuity: 0) {
            bytes.append(packet)
        }

        _ = demuxer.feed(bytes)
        let frames = demuxer.flush().compactMap { event -> GoProAudioFrame? in
            guard case .audioFrame(let frame) = event else { return nil }
            return frame
        }

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.aacData, aacPayload)
    }

    func testFramesWithoutAPESTimestampStillAdvance() {
        let demuxer = GoProTsDemuxer()
        let es = AudioStreamBuilder.adtsFrame(payload: aacPayload) + AudioStreamBuilder.adtsFrame(payload: secondPayload)

        var bytes = AudioStreamBuilder.header()
        for packet in AudioStreamBuilder.packets(AudioStreamBuilder.audioPES(es: es, pts: nil), continuity: 0) {
            bytes.append(packet)
        }

        _ = demuxer.feed(bytes)
        let frames = demuxer.flush().compactMap { event -> GoProAudioFrame? in
            guard case .audioFrame(let frame) = event else { return nil }
            return frame
        }

        guard frames.count == 2 else { return XCTFail("expected 2 reassembled frames, got \(frames.count)") }
        XCTAssertGreaterThan(frames[1].presentationTime, frames[0].presentationTime)
    }

    func testResetClearsTheAudioPIDAndClock() {
        let demuxer = GoProTsDemuxer()
        _ = demuxer.feed(AudioStreamBuilder.header())
        XCTAssertNotNil(demuxer.audioPID)

        demuxer.reset()
        XCTAssertNil(demuxer.audioPID)
        XCTAssertEqual(demuxer.statistics.audioPackets, 0)
    }
}
