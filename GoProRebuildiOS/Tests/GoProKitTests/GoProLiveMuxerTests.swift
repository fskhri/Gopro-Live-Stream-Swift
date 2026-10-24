import XCTest
@testable import GoProKit

/// The ordering rules a player on the other end depends on, checked without a
/// camera: nothing flows before the configuration, the configuration goes out
/// once per change, and both tracks share one timestamp base.
final class GoProLiveMuxerTests: XCTestCase {
    private let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xAB])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])

    private func keyframe(decodeTime: Double = 0) -> GoProAccessUnit {
        GoProAccessUnit(
            avccData: Data([0x00, 0x00, 0x00, 0x04, 0x65, 0x01, 0x02, 0x03]),
            isKeyFrame: true,
            presentationTime: decodeTime,
            decodeTime: decodeTime
        )
    }

    private func interFrame(decodeTime: Double) -> GoProAccessUnit {
        GoProAccessUnit(
            avccData: Data([0x00, 0x00, 0x00, 0x04, 0x41, 0x01, 0x02, 0x03]),
            isKeyFrame: false,
            presentationTime: decodeTime,
            decodeTime: decodeTime
        )
    }

    private func audio(presentationTime: Double = 0, channels: Int = 1) -> GoProAudioFrame {
        // AudioSpecificConfig: profile 2, 48 kHz, `channels` channels.
        let config = Self.audioSpecificConfig(sampleRateIndex: 3, channels: channels)
        return GoProAudioFrame(
            aacData: Data([0x01, 0x02, 0x03, 0x04]),
            presentationTime: presentationTime,
            audioSpecificConfig: config
        )
    }

    /// 16 bits: 5 profile, 4 frequency index, 4 channel count, 3 padding.
    static func audioSpecificConfig(sampleRateIndex: Int, channels: Int) -> Data {
        let value = (2 << 11) | (sampleRateIndex << 7) | (channels << 3)
        return Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    // MARK: - Video

    func testNothingIsPushedBeforeTheParameterSetsArrive() {
        var muxer = GoProLiveMuxer()

        XCTAssertTrue(muxer.mux(.accessUnit(keyframe())).isEmpty)
        XCTAssertEqual(muxer.videoTags, 0)
    }

    func testFramesBeforeAKeyframeAreHeldBack() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))

        XCTAssertTrue(muxer.mux(.accessUnit(interFrame(decodeTime: 0.1))).isEmpty)
        XCTAssertEqual(muxer.videoTags, 0)
    }

    func testFirstKeyframeSendsMetadataThenHeaderThenFrame() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))

        let outputs = muxer.mux(.accessUnit(keyframe(decodeTime: 0.5)))

        XCTAssertEqual(outputs.count, 3)
        guard case .metadata = outputs[0] else { return XCTFail("expected metadata first") }
        guard case .videoSequenceHeader(let header, let headerTime) = outputs[1] else {
            return XCTFail("expected the AVC configuration")
        }
        guard case .video(let tag, let frameTime) = outputs[2] else {
            return XCTFail("expected the frame")
        }

        XCTAssertEqual(Array(header.prefix(5)), [0x17, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(headerTime, 0)
        XCTAssertEqual(frameTime, 0)
        XCTAssertEqual(Array(tag.prefix(5)), [0x17, 0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(muxer.videoTags, 1)
        XCTAssertEqual(muxer.bytesSent, header.count + tag.count)
    }

    func testTheHeaderIsNotRepeatedForEveryFrame() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))
        _ = muxer.mux(.accessUnit(keyframe(decodeTime: 0)))

        let outputs = muxer.mux(.accessUnit(interFrame(decodeTime: 0.04)))
        XCTAssertEqual(outputs.count, 1)
        guard case .video = outputs[0] else { return XCTFail("expected a single frame") }
        XCTAssertEqual(muxer.videoTags, 2)
    }

    func testNewParameterSetsSendTheHeaderAgainOnTheNextKeyframe() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))
        _ = muxer.mux(.accessUnit(keyframe(decodeTime: 0)))

        muxer.mux(.parameterSets(sps: sps, pps: pps))
        // Same bytes: nothing to redo.
        let unchanged = muxer.mux(.accessUnit(interFrame(decodeTime: 0.04)))
        XCTAssertEqual(unchanged.count, 1)

        // Different bytes: the header has to describe the new configuration,
        // and it has to wait for a keyframe the player can start from.
        let changedSPS = Data([0x67, 0x42, 0xC0, 0x1F, 0xCD])
        muxer.mux(.parameterSets(sps: changedSPS, pps: pps))
        XCTAssertTrue(muxer.mux(.accessUnit(interFrame(decodeTime: 0.08))).isEmpty)

        let outputs = muxer.mux(.accessUnit(keyframe(decodeTime: 0.12)))
        XCTAssertEqual(outputs.count, 3)
        guard case .videoSequenceHeader(let header, _) = outputs[1] else {
            return XCTFail("expected the header before the keyframe")
        }
        XCTAssertTrue(header.contains(changedSPS))
        guard case .video = outputs[2] else { return XCTFail("expected the keyframe") }
    }

    func testMetadataIsSentOncePerConfiguration() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))
        _ = muxer.mux(.accessUnit(keyframe(decodeTime: 0)))

        var metadataCount = 0
        for time in stride(from: 0.04, through: 0.4, by: 0.04) {
            for output in muxer.mux(.accessUnit(interFrame(decodeTime: time))) {
                if case .metadata = output { metadataCount += 1 }
            }
        }
        XCTAssertEqual(metadataCount, 0)

        muxer.mux(.parameterSets(sps: Data([0x67, 0x42, 0xC0, 0x1E, 0xFE]), pps: pps))
        let outputs = muxer.mux(.accessUnit(keyframe(decodeTime: 0.5)))
        XCTAssertEqual(outputs.count, 3)
        guard case .metadata = outputs[0] else { return XCTFail("expected metadata with the new configuration") }
        guard case .videoSequenceHeader = outputs[1] else { return XCTFail("expected the header") }
        guard case .video = outputs[2] else { return XCTFail("expected the keyframe") }
    }

    // MARK: - Audio

    func testFirstAudioFrameSendsTheConfigurationBeforeTheFrame() {
        var muxer = GoProLiveMuxer()

        let outputs = muxer.mux(.audioFrame(audio(channels: 2)))

        XCTAssertEqual(outputs.count, 2)
        guard case .audioSequenceHeader(let header, _) = outputs[0] else {
            return XCTFail("expected the audio configuration")
        }
        guard case .audio(let tag, _) = outputs[1] else {
            return XCTFail("expected the frame")
        }
        XCTAssertEqual(header, Data([0xAF, 0x00]) + Self.audioSpecificConfig(sampleRateIndex: 3, channels: 2))
        XCTAssertEqual(tag, Data([0xAF, 0x01, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(muxer.audioTags, 1)
        XCTAssertEqual(muxer.audioSampleRate, 48000)
        XCTAssertEqual(muxer.audioChannels, 2)
    }

    func testLaterAudioFramesCarryOnlyTheFrame() {
        var muxer = GoProLiveMuxer()
        _ = muxer.mux(.audioFrame(audio(presentationTime: 1.0)))

        let outputs = muxer.mux(.audioFrame(audio(presentationTime: 1.023)))
        XCTAssertEqual(outputs.count, 1)
        guard case .audio(let tag, let timestamp) = outputs[0] else {
            return XCTFail("expected a single frame")
        }
        XCTAssertEqual(timestamp, 23)
        XCTAssertEqual(tag, Data([0xAE, 0x01, 0x01, 0x02, 0x03, 0x04]))
    }

    func testMetadataKnowsTheAudioOnceItHasArrived() {
        var muxer = GoProLiveMuxer()
        _ = muxer.mux(.audioFrame(audio(channels: 2)))
        muxer.mux(.parameterSets(sps: sps, pps: pps))

        let outputs = muxer.mux(.accessUnit(keyframe(decodeTime: 0.5)))
        guard case .metadata = outputs[0] else { return XCTFail("expected metadata first") }
        XCTAssertEqual(muxer.audioSampleRate, 48000)
        XCTAssertEqual(muxer.audioChannels, 2)
    }

    // MARK: - Timestamps

    func testBothTracksShareOneTimestampBase() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))

        // Audio is first in the stream but both tracks count from it.
        let first = muxer.mux(.audioFrame(audio(presentationTime: 42.0)))
        XCTAssertEqual(first.map { $0.timestampMS }, [0, 0])

        let video = muxer.mux(.accessUnit(keyframe(decodeTime: 42.05)))
        // metadata (always timestamped 0), the header, then the keyframe.
        XCTAssertEqual(video.map { $0.timestampMS }, [0, 50, 50])
        XCTAssertEqual(video.count, 3)

        let more = muxer.mux(.accessUnit(interFrame(decodeTime: 42.083)))
        XCTAssertEqual(more.map { $0.timestampMS }, [83])
    }

    func testResetForgetsTheConfigurationAndTheCounts() {
        var muxer = GoProLiveMuxer()
        muxer.mux(.parameterSets(sps: sps, pps: pps))
        _ = muxer.mux(.accessUnit(keyframe(decodeTime: 1)))
        _ = muxer.mux(.audioFrame(audio(presentationTime: 1)))
        XCTAssertEqual(muxer.videoTags, 1)
        XCTAssertEqual(muxer.audioTags, 1)

        muxer.reset()

        XCTAssertEqual(muxer.videoTags, 0)
        XCTAssertEqual(muxer.audioTags, 0)
        XCTAssertEqual(muxer.bytesSent, 0)
        XCTAssertNil(muxer.audioSampleRate)
        XCTAssertTrue(muxer.mux(.accessUnit(keyframe(decodeTime: 1))).isEmpty)
    }
}

final class GoProAudioConfigTests: XCTestCase {
    func testReadsChannelCountAndSampleRateFromTheConfig() {
        let mono48k = GoProLiveMuxerTests.audioSpecificConfig(sampleRateIndex: 3, channels: 1)
        XCTAssertEqual(GoProFlvMuxer.channels(ofAudioSpecificConfig: mono48k), 1)
        XCTAssertEqual(GoProFlvMuxer.sampleRate(ofAudioSpecificConfig: mono48k), 48000)

        let stereo44k = GoProLiveMuxerTests.audioSpecificConfig(sampleRateIndex: 4, channels: 2)
        XCTAssertEqual(GoProFlvMuxer.channels(ofAudioSpecificConfig: stereo44k), 2)
        XCTAssertEqual(GoProFlvMuxer.sampleRate(ofAudioSpecificConfig: stereo44k), 44100)

        let sixChannel = GoProLiveMuxerTests.audioSpecificConfig(sampleRateIndex: 3, channels: 6)
        XCTAssertEqual(GoProFlvMuxer.channels(ofAudioSpecificConfig: sixChannel), 6)
    }

    func testSurvivesAConfigThatIsNotThere() {
        XCTAssertEqual(GoProFlvMuxer.channels(ofAudioSpecificConfig: Data([0x11])), 1)
        XCTAssertEqual(GoProFlvMuxer.sampleRate(ofAudioSpecificConfig: Data([0x11])), 0)
        XCTAssertEqual(GoProFlvMuxer.channels(ofAudioSpecificConfig: Data()), 1)
    }
}
