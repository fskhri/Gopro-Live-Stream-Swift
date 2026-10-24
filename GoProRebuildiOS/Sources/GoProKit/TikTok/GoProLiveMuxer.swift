import Foundation

/// Turns demux events into the tag bodies an RTMP ingest expects, in order.
///
/// Pure and synchronous: no network, no locks, no tasks. The streamer owns the
/// connection and drives this one event at a time, which keeps the whole
/// ordering problem in a file that can be tested without a camera or a server.
///
/// The rules it encodes, all of which a player depends on:
///
/// - A sequence header goes out before the first frame of a stream, and again
///   whenever the SPS/PPS change.
/// - It never goes out mid-GOP: everything after it would reference frames the
///   player was never given.
/// - Audio configuration comes from the camera's own `AudioSpecificConfig`,
///   passed through untouched rather than re-encoded.
/// - Timestamps are milliseconds from the first frame sent, not per track.
public struct GoProLiveMuxer: Sendable {
    /// One write, in the order the streamer has to make it.
    public enum Output: Equatable, Sendable {
        /// `@setDataFrame` metadata; read the rate and channels from the
        /// muxer when sending it.
        case metadata
        case videoSequenceHeader(Data, timestampMS: UInt32)
        case video(Data, timestampMS: UInt32)
        case audioSequenceHeader(Data, timestampMS: UInt32)
        case audio(Data, timestampMS: UInt32)

        /// The one timestamp that matters, `0` for metadata.
        public var timestampMS: UInt32 {
            switch self {
            case .metadata:
                return 0
            case .videoSequenceHeader(_, let timestamp),
                 .video(_, let timestamp),
                 .audioSequenceHeader(_, let timestamp),
                 .audio(_, let timestamp):
                return timestamp
            }
        }
    }

    public private(set) var videoTags = 0
    public private(set) var audioTags = 0
    public private(set) var bytesSent = 0
    /// From the first `AudioSpecificConfig` seen, for the metadata. `nil`
    /// until something has read it, so a missing claim is not replaced by a
    /// wrong one.
    public private(set) var audioSampleRate: Double?
    public private(set) var audioChannels: Int?
    /// Set when a frame could not be turned into a tag. Worth surfacing: the
    /// alternative is a stream that quietly shows nothing.
    public private(set) var lastWarning: String?

    private var sps: Data?
    private var pps: Data?
    private var videoHeaderSent = false
    private var audioHeaderSent = false
    private var metadataSent = false
    private var epoch: Double?

    public init() {}

    /// Forget everything, as if a new room had just opened.
    public mutating func reset() {
        sps = nil
        pps = nil
        videoHeaderSent = false
        audioHeaderSent = false
        metadataSent = false
        epoch = nil
        audioSampleRate = nil
        audioChannels = nil
        lastWarning = nil
        videoTags = 0
        audioTags = 0
        bytesSent = 0
    }

    /// Marks that sequence headers and metadata are owed to a newly (re)connected ingest.
    ///
    /// Preserves cached SPS/PPS and epoch so timestamps remain continuous while
    /// sending parameter sets on the next keyframe.
    public mutating func markHeadersNeeded() {
        videoHeaderSent = false
        audioHeaderSent = false
        metadataSent = false
    }

    /// One demux event in, zero or more ordered writes out.
    public mutating func mux(_ event: GoProDemuxEvent) -> [Output] {
        switch event {
        case .parameterSets(let sps, let pps):
            if sps != self.sps || pps != self.pps {
                self.sps = sps
                self.pps = pps
                videoHeaderSent = false
                metadataSent = false
            }
            return []
        case .accessUnit(let unit):
            return muxVideo(unit)
        case .audioFrame(let frame):
            return muxAudio(frame)
        }
    }

    private mutating func muxVideo(_ unit: GoProAccessUnit) -> [Output] {
        var outputs: [Output] = []

        if !videoHeaderSent {
            // Before the first frame the decoder configuration is owed, but
            // only once the camera has handed over the parameter sets, and
            // only on a keyframe.
            guard let sps, let pps else { return outputs }
            guard unit.isKeyFrame else { return outputs }

            if !metadataSent {
                metadataSent = true
                outputs.append(.metadata)
            }

            guard let header = GoProFlvMuxer.videoSequenceHeader(sps: sps, pps: pps) else {
                lastWarning = "The camera sent parameter sets this app cannot encode."
                return outputs
            }

            let timestamp = timestampMS(unit.decodeTime)
            outputs.append(.videoSequenceHeader(header, timestampMS: timestamp))
            bytesSent += header.count
            videoHeaderSent = true
        }

        let tag = GoProFlvMuxer.videoTag(unit)
        outputs.append(.video(tag, timestampMS: timestampMS(unit.decodeTime)))
        videoTags += 1
        bytesSent += tag.count
        return outputs
    }

    private mutating func muxAudio(_ frame: GoProAudioFrame) -> [Output] {
        var outputs: [Output] = []
        let channels = GoProFlvMuxer.channels(ofAudioSpecificConfig: frame.audioSpecificConfig)

        if !audioHeaderSent {
            let header = GoProFlvMuxer.audioSequenceHeader(
                config: frame.audioSpecificConfig,
                channels: channels
            )
            outputs.append(.audioSequenceHeader(header, timestampMS: timestampMS(frame.presentationTime)))
            bytesSent += header.count
            audioHeaderSent = true

            let rate = GoProFlvMuxer.sampleRate(ofAudioSpecificConfig: frame.audioSpecificConfig)
            audioSampleRate = rate > 0 ? Double(rate) : nil
            audioChannels = channels
        }

        let tag = GoProFlvMuxer.audioTag(frame, channels: channels)
        outputs.append(.audio(tag, timestampMS: timestampMS(frame.presentationTime)))
        audioTags += 1
        bytesSent += tag.count
        return outputs
    }

    /// Milliseconds from the first frame of the session. The first timestamp
    /// anchors every track, so audio and video stay in step. Rounded rather
    /// than truncated: 0.083 s is 83 ms, not 82.
    private mutating func timestampMS(_ time: Double) -> UInt32 {
        if epoch == nil { epoch = time }
        let delta = (time - (epoch ?? time)) * 1000
        let clamped = min(max(delta, 0), Double(UInt32.max))
        return UInt32(clamped.rounded())
    }
}
