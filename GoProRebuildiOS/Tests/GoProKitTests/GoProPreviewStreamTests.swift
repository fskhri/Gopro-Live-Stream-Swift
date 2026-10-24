import XCTest
@testable import GoProKit

// MARK: - Test stream builder

/// Builds a synthetic GoPro preview stream: PAT, PMT, and H.264 PES packets.
///
/// The PMT declares the same two entries the camera does: a real H.264 stream
/// and the private `0x80` stream that never carries payload.
private enum PreviewStreamBuilder {
    static let pmtPID = 0x1000
    static let videoPID = 0x100
    static let privatePID = 0x200

    static let aud = Data([0x09, 0x10])
    static let spsA = Data([0x67, 0x64, 0x00, 0x1E, 0xAC, 0xD9, 0x40, 0xA0, 0x2F, 0xF9, 0x70, 0x11, 0x00, 0x00, 0x03, 0x00, 0x01])
    static let spsB = Data([0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0xA0, 0x2F, 0xF9, 0x70, 0x11, 0x00, 0x00, 0x03, 0x00, 0x01])
    static let pps = Data([0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0])
    static let idr = Data([0x65, 0x88, 0x84, 0x10, 0x21, 0xFF, 0xEE, 0xDD])
    static let slice = Data([0x41, 0x9A, 0x11, 0x22, 0x33])

    /// One TS packet: header plus payload, adaptation field when it will not fit.
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
        section.append(contentsOf: [0x00, 0x01])  // transport stream id
        section.append(0xC1)                      // current_next = 1
        section.append(contentsOf: [0x00, 0x00])  // section / last section
        section.append(contentsOf: [0x00, 0x01])  // program number
        section.append(UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)))
        section.append(UInt8(pmtPID & 0xFF))
        section.append(contentsOf: [0, 0, 0, 0])  // CRC, unchecked by the demuxer

        // The pointer field precedes the table inside the first payload byte.
        return Data([0x00]) + section
    }

    static func pmt(includingPrivateStream: Bool) -> Data {
        let streamCount = includingPrivateStream ? 2 : 1
        let sectionLength = 9 + (streamCount * 5) + 4

        var section = Data([0x02, 0xB0 | UInt8((sectionLength >> 8) & 0x0F), UInt8(sectionLength & 0xFF)])
        section.append(contentsOf: [0x00, 0x01])  // program number
        section.append(0xC1)
        section.append(contentsOf: [0x00, 0x00])
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))  // PCR pid
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])  // program info length, none

        section.append(GoProPreviewConfiguration.h264StreamType)
        section.append(UInt8(0xE0 | ((videoPID >> 8) & 0x1F)))
        section.append(UInt8(videoPID & 0xFF))
        section.append(contentsOf: [0xF0, 0x00])

        if includingPrivateStream {
            // The GoPro private stream: declared on a PID that never has payload.
            section.append(GoProPreviewConfiguration.privateStreamType)
            section.append(UInt8(0xE0 | ((privatePID >> 8) & 0x1F)))
            section.append(UInt8(privatePID & 0xFF))
            section.append(contentsOf: [0xF0, 0x00])
        }

        section.append(contentsOf: [0, 0, 0, 0])  // CRC
        return Data([0x00]) + section
    }

    /// Annex-B bytes: four-byte start code before each NAL unit.
    static func annexB(_ nals: [Data]) -> Data {
        nals.reduce(into: Data()) { stream, nal in
            stream.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            stream.append(nal)
        }
    }

    /// One PES packet with a single PTS timestamp.
    static func pes(es: Data, pts: Double) -> Data {
        var pes = Data([0x00, 0x00, 0x01, 0xE0])
        let pesLength = 3 + 5 + es.count
        pes.append(UInt8((pesLength >> 8) & 0xFF))
        pes.append(UInt8(pesLength & 0xFF))
        pes.append(contentsOf: [0x80, 0x80, 0x05])  // PTS only, header data length 5
        pes.append(timestamp(pts))
        pes.append(es)
        return pes
    }

    /// Five-byte PES timestamp with its marker bits.
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

    /// TS packets for one PES packet on the video PID.
    static func videoPackets(_ pes: Data, startingContinuity: UInt8) -> [Data] {
        videoPacketsFor(pes, pid: videoPID, startingContinuity: startingContinuity)
    }

    /// PAT, PMT, then two frames: one IDR and one inter-frame.
    ///
    /// - Parameter secondFrameContinuity: continuity counter written on the
    ///   second frame's first packet. The natural value is 1; passing a
    ///   different one produces the gap a lost datagram would cause.
    static func stream(includingPrivateStream: Bool = true, secondFrameContinuity: UInt8 = 1) -> Data {
        var bytes = Data()
        bytes.append(tsPacket(pid: 0, payloadUnitStart: true, continuity: 0, payload: pat()))
        bytes.append(tsPacket(pid: pmtPID, payloadUnitStart: true, continuity: 0, payload: pmt(includingPrivateStream: includingPrivateStream)))

        let firstFrame = pes(es: annexB([aud, spsA, pps, idr]), pts: 1.0)
        let secondFrame = pes(es: annexB([aud, slice]), pts: 1.033333)

        var continuity: UInt8 = 0
        for packet in videoPackets(firstFrame, startingContinuity: continuity) {
            bytes.append(packet)
            continuity = packet[3] & 0x0F
        }
        for packet in videoPackets(secondFrame, startingContinuity: secondFrameContinuity) {
            bytes.append(packet)
        }

        if includingPrivateStream {
            // Frames on the private PID must never reach the output.
            let stray = pes(es: annexB([aud, idr]), pts: 99.0)
            for packet in videoPacketsFor(stray, pid: privatePID, startingContinuity: 0) {
                bytes.append(packet)
            }
        }
        return bytes
    }

    private static func videoPacketsFor(_ pes: Data, pid: Int, startingContinuity: UInt8) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        var continuity = startingContinuity

        while offset < pes.count {
            let isFirst = offset == 0
            let capacity = 184 - (isFirst ? 1 : 0)
            let end = min(offset + capacity, pes.count)

            var payload = Data()
            if isFirst { payload.append(0x00) }
            payload.append(Data(pes[pes.startIndex + offset..<pes.startIndex + end]))

            packets.append(tsPacket(pid: pid, payloadUnitStart: isFirst, continuity: continuity, payload: payload))
            offset = end
            continuity = continuity == 0x0F ? 0 : continuity &+ 1
        }
        return packets
    }
}

private extension Data {
    func chunked(into size: Int) -> [Data] {
        var chunks: [Data] = []
        var offset = startIndex
        while offset < endIndex {
            let end = Swift.min(offset + size, endIndex)
            chunks.append(Data(self[offset..<end]))
            offset = end
        }
        return chunks
    }
}

// MARK: - Datagram stripper

final class GoProDatagramStripperTests: XCTestCase {
    private let tsBytes = Data(repeating: 0x47, count: 188 * 2)

    func testStripsHeaderAndReportsDeclaredLength() throws {
        let datagram = GoProDatagramStripper.frame(payload: tsBytes, sequence: 7)

        let result = try GoProDatagramStripper.strip(datagram)

        XCTAssertEqual(result.payload, tsBytes)
        XCTAssertEqual(result.datagramLength, 12 + tsBytes.count)
        XCTAssertEqual(result.padding, 0)
        XCTAssertTrue(result.usedDeclaredLength)
    }

    func testMissingSyncBytePassesWholeDatagramThrough() throws {
        var datagram = GoProDatagramStripper.frame(payload: tsBytes, sequence: 3)
        // Break the sync byte so the datagram is not framed as a preview packet.
        datagram[12] = 0x11

        let result = try GoProDatagramStripper.strip(datagram)

        XCTAssertEqual(result.payload, datagram)
        XCTAssertFalse(result.usedDeclaredLength)
    }

    func testDeclaredLengthBeyondAvailableFallsBackToAvailable() throws {
        let datagram = GoProDatagramStripper.frame(payload: tsBytes, sequence: 9, declaredLength: 4096)

        let result = try GoProDatagramStripper.strip(datagram)

        XCTAssertEqual(result.payload, tsBytes)
        XCTAssertEqual(result.padding, 0)
        XCTAssertFalse(result.usedDeclaredLength)
    }

    func testDeclaredLengthZeroFallsBackToAvailable() throws {
        let datagram = GoProDatagramStripper.frame(payload: tsBytes, sequence: 0, declaredLength: 0)

        let result = try GoProDatagramStripper.strip(datagram)

        XCTAssertEqual(result.payload, tsBytes)
        XCTAssertFalse(result.usedDeclaredLength)
    }

    func testShorterThanHeaderThrows() {
        XCTAssertThrowsError(try GoProDatagramStripper.strip(Data(repeating: 0, count: 12))) { error in
            XCTAssertEqual(error as? GoProDatagramStripper.StripError, .tooShort(12))
        }
    }

    func testEmptyDatagramThrows() {
        XCTAssertThrowsError(try GoProDatagramStripper.strip(Data())) { error in
            XCTAssertEqual(error as? GoProDatagramStripper.StripError, .empty)
        }
    }

    func testUnalignedPayloadIsStillStripped() throws {
        // The camera pads with zeros; a declared length shorter than the
        // available bytes leaves trailing padding behind.
        let payload = Data(repeating: 0x47, count: 188)
        let datagram = GoProDatagramStripper.frame(payload: payload, sequence: 5, declaredLength: 188)

        let result = try GoProDatagramStripper.strip(datagram)

        XCTAssertEqual(result.payload, payload)
        XCTAssertEqual(result.padding, 0)
        XCTAssertTrue(result.usedDeclaredLength)
    }
}

// MARK: - Transport stream demuxer

final class GoProTsDemuxerTests: XCTestCase {
    private func demux(_ bytes: Data, chunkSize: Int = 200) -> (GoProTsDemuxer, [GoProDemuxEvent]) {
        let demuxer = GoProTsDemuxer()
        var events: [GoProDemuxEvent] = []
        for chunk in bytes.chunked(into: chunkSize) {
            events.append(contentsOf: demuxer.feed(chunk))
        }
        events.append(contentsOf: demuxer.flush())
        return (demuxer, events)
    }

    func testEmitsParameterSetsAndTwoAccessUnits() {
        let (demuxer, events) = demux(PreviewStreamBuilder.stream())

        XCTAssertEqual(events.count, 3, "expected parameter sets plus two frames, got \(events)")
        XCTAssertEqual(demuxer.videoPID, PreviewStreamBuilder.videoPID)

        guard case .parameterSets(let sps, let pps) = events[0] else {
            return XCTFail("first event should be parameter sets, got \(events[0])")
        }
        XCTAssertEqual(sps, PreviewStreamBuilder.spsA)
        XCTAssertEqual(pps, PreviewStreamBuilder.pps)

        guard case .accessUnit(let first) = events[1] else {
            return XCTFail("second event should be an access unit, got \(events[1])")
        }
        XCTAssertTrue(first.isKeyFrame)
        XCTAssertEqual(first.presentationTime, 1.0, accuracy: 0.0001)

        guard case .accessUnit(let second) = events[2] else {
            return XCTFail("third event should be an access unit, got \(events[2])")
        }
        XCTAssertFalse(second.isKeyFrame)
        XCTAssertEqual(second.presentationTime, 1.0333, accuracy: 0.0001)
    }

    func testAccessUnitUsesAVCCLengthPrefixes() {
        let (_, events) = demux(PreviewStreamBuilder.stream(includingPrivateStream: false))

        guard case .accessUnit(let first) = events[1] else {
            return XCTFail("expected an access unit, got \(events[1])")
        }

        var expected = Data()
        for nal in [PreviewStreamBuilder.spsA, PreviewStreamBuilder.pps, PreviewStreamBuilder.idr] {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { expected.append(contentsOf: $0) }
            expected.append(nal)
        }
        XCTAssertEqual(first.avccData, expected)
    }

    func testPrivateStreamProducesNoOutput() {
        // The stream includes a full IDR frame on the private PID. Nothing from
        // it may surface, which is the port of GoProTsExtractorFactory's drop.
        let (demuxer, events) = demux(PreviewStreamBuilder.stream())

        XCTAssertEqual(demuxer.videoPID, PreviewStreamBuilder.videoPID)
        XCTAssertEqual(events.count, 3)
        for event in events {
            if case .accessUnit(let unit) = event {
                XCTAssertLessThan(unit.presentationTime, 10, "private PID frame leaked into output")
            }
        }
    }

    func testContinuityGapIsCountedAndDiscarded() {
        // The second frame starts two counters early, the gap a dropped
        // datagram leaves behind. Its first packet is discarded, and with it
        // the frame, but the frame already assembled before the gap survives.
        let bytes = PreviewStreamBuilder.stream(includingPrivateStream: false, secondFrameContinuity: 3)

        let (demuxer, events) = demux(bytes)

        XCTAssertEqual(demuxer.statistics.discontinuities, 1)
        XCTAssertEqual(demuxer.statistics.droppedPackets, 1)
        XCTAssertEqual(events.count, 2, "only the intact frame should survive, got \(events)")
    }

    func testChangedParameterSetsEmitAgain() {
        var bytes = Data()
        bytes.append(PreviewStreamBuilder.tsPacket(pid: 0, payloadUnitStart: true, continuity: 0, payload: PreviewStreamBuilder.pat()))
        bytes.append(PreviewStreamBuilder.tsPacket(pid: PreviewStreamBuilder.pmtPID, payloadUnitStart: true, continuity: 0, payload: PreviewStreamBuilder.pmt(includingPrivateStream: false)))

        let frames = [
            (PreviewStreamBuilder.annexB([PreviewStreamBuilder.aud, PreviewStreamBuilder.spsA, PreviewStreamBuilder.pps, PreviewStreamBuilder.idr]), 1.0),
            (PreviewStreamBuilder.annexB([PreviewStreamBuilder.aud, PreviewStreamBuilder.spsB, PreviewStreamBuilder.pps, PreviewStreamBuilder.idr]), 2.0),
        ]

        var continuity: UInt8 = 0
        for (es, pts) in frames {
            for packet in PreviewStreamBuilder.videoPackets(
                PreviewStreamBuilder.pes(es: es, pts: pts),
                startingContinuity: continuity
            ) {
                bytes.append(packet)
                continuity = packet[3] & 0x0F
            }
            continuity = continuity == 0x0F ? 0 : continuity &+ 1
        }

        let (_, events) = demux(bytes)

        let parameterSets = events.filter { if case .parameterSets = $0 { return true }; return false }
        XCTAssertEqual(parameterSets.count, 2, "a changed SPS must reach the decoder again, got \(events)")
    }

    func testSplitNALUnitsHandlesBothStartCodeLengths() {
        // media3's rule: a zero in front of a three-byte start code is read as
        // the extra zero of a four-byte one, so the NAL above has no trailing
        // zero. A NAL that really ends in zero has it taken by the delimiter.
        let nal1 = Data([0x67, 0x64, 0x11])
        let nal2 = Data([0x68, 0xEB, 0xE3])
        let bytes = Data([0, 0, 0, 1]) + nal1 + Data([0, 0, 1]) + nal2

        XCTAssertEqual(GoProTsDemuxer.splitNALUnits(bytes), [nal1, nal2])
    }

    func testSplitNALUnitsKeepsTrailingZeroOfFourByteDelimitedNAL() {
        let nal1 = Data([0x67, 0x64, 0x00])
        let nal2 = Data([0x68, 0xEB, 0xE3])
        let bytes = Data([0, 0, 0, 1]) + nal1 + Data([0, 0, 0, 1]) + nal2

        XCTAssertEqual(GoProTsDemuxer.splitNALUnits(bytes), [nal1, nal2])
    }

    func testTimestampRoundTripsThroughFiftyThreeBitTicks() {
        let ticks: UInt64 = 90_000 * 5  // exactly five seconds
        let packed = PreviewStreamBuilder.timestamp(5.0)

        let decoded = GoProTsDemuxer.timestamp(at: 0, in: packed)

        XCTAssertEqual(decoded, 5.0, accuracy: 0.0001)
        XCTAssertEqual(UInt64((decoded * 90_000).rounded()), ticks)
    }

    func testResetClearsState() {
        let (_, events) = demux(PreviewStreamBuilder.stream())
        XCTAssertEqual(events.count, 3)

        let demuxer = GoProTsDemuxer()
        demuxer.reset()
        XCTAssertEqual(demuxer.videoPID, nil)
        XCTAssertEqual(demuxer.statistics.discontinuities, 0)
    }

    func testDemuxerRetainsCurrentParameterSets() {
        let (demuxer, _) = demux(PreviewStreamBuilder.stream())
        XCTAssertNotNil(demuxer.currentParameterSets)
        XCTAssertEqual(demuxer.currentParameterSets?.sps, PreviewStreamBuilder.spsA)
        XCTAssertEqual(demuxer.currentParameterSets?.pps, PreviewStreamBuilder.pps)
    }
}
