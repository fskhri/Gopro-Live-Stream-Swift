import Foundation

/// Builds FLV audio and video tags, the message bodies an RTMP `publish` sends.
///
/// Replaces the half of `ffmpeg -c:v copy -f flv` that produced the container.
/// There is no FLV file header here: a live push sends one tag body per RTMP
/// message and never writes the 9-byte preamble a saved `.flv` would carry.
///
/// H.264 arrives as AVCC, which is what the demuxer already produces, so video
/// is copied rather than re-encoded. AAC is copied as-is too, which is where
/// Android differed: ffmpeg re-encoded it to 44.1 kHz stereo because TikTok
/// asks for that shape. The camera's own rate and channel count are passed
/// through here, and they travel inside the `AudioSpecificConfig`, which is what
/// a decoder actually reads.
public enum GoProFlvMuxer {

    /// FLV audio header: 10 = AAC, then rate, sample size and channel count.
    ///
    /// The rate bits are written as 44 kHz whatever the stream carries, which is
    /// what the FLV specification requires for AAC and what ffmpeg emits. The
    /// real rate is the one inside the `AudioSpecificConfig`.
    public static func audioHeader(channels: Int) -> UInt8 {
        let aacRate = UInt8(3)
        let sixteenBit = UInt8(1)
        let stereo = channels > 1 ? UInt8(1) : UInt8(0)
        return (10 << 4) | (aacRate << 2) | (sixteenBit << 1) | stereo
    }

    // MARK: - Audio

    /// AAC sequence header: the header byte, AACPacketType 0, then the config.
    public static func audioSequenceHeader(config: Data, channels: Int = 1) -> Data {
        var tag = Data([
            audioHeader(channels: channels),
            0x00,  // AACPacketType: sequence header
        ])
        tag.append(config)
        return tag
    }

    /// One AAC frame: the header byte, AACPacketType 1, then the raw frame.
    public static func audioTag(_ frame: GoProAudioFrame, channels: Int = 1) -> Data {
        var tag = Data([
            audioHeader(channels: channels),
            0x01,  // AACPacketType: raw frame
        ])
        tag.append(frame.aacData)
        return tag
    }

    // MARK: - Video

    /// `AVCDecoderConfigurationRecord`, the body of an AVC sequence header.
    ///
    /// SPS bytes 1...3 carry the profile, compatibility and level; the record
    /// stores them as-is so the decoder can pick a profile without parsing the
    /// Exp-Golomb fields that follow.
    public static func avcDecoderConfigurationRecord(sps: Data, pps: Data) -> Data? {
        guard sps.count > 3, !pps.isEmpty else { return nil }
        // NAL unit type is in bits 0-4; bits 5-6 are nal_ref_idc which varies.
        guard (sps[0] & 0x1F) == 7, (pps[0] & 0x1F) == 8 else { return nil }
        guard sps.count <= 0xFFFF, pps.count <= 0xFFFF else { return nil }

        var record = Data()
        record.append(0x01)  // configurationVersion
        record.append(sps[1])  // AVCProfileIndication
        record.append(sps[2])  // profile_compatibility
        record.append(sps[3])  // AVCLevelIndication

        // 111111 + lengthSizeMinusOne (3): length prefixes stay 4 bytes, the
        // same layout the demuxer emits.
        record.append(0xFF)
        // 111 + one sequence parameter set.
        record.append(0xE1)
        record.append(UInt8((sps.count >> 8) & 0xFF))
        record.append(UInt8(sps.count & 0xFF))
        record.append(sps)

        record.append(0x01)  // one picture parameter set
        record.append(UInt8((pps.count >> 8) & 0xFF))
        record.append(UInt8(pps.count & 0xFF))
        record.append(pps)
        return record
    }

    /// AVC sequence header tag: keyframe flag, AVC, packet type 0, zero time.
    public static func videoSequenceHeader(sps: Data, pps: Data) -> Data? {
        guard let record = avcDecoderConfigurationRecord(sps: sps, pps: pps) else { return nil }
        var tag = Data([
            videoHeader(isKeyFrame: true),
            0x00,  // AVCPacketType: sequence header
            0x00, 0x00, 0x00,  // composition time
        ])
        tag.append(record)
        return tag
    }

    /// One video access unit: frame type, AVC, packet type 1, then the AVCC
    /// bytes the demuxer produced.
    public static func videoTag(_ unit: GoProAccessUnit) -> Data {
        var tag = Data([
            videoHeader(isKeyFrame: unit.isKeyFrame),
            0x01,  // AVCPacketType: NALU
            0x00, 0x00, 0x00,  // composition time, PTS equals DTS here
        ])
        tag.append(unit.avccData)
        return tag
    }

    /// FLV video header: frame type in the high nibble, codec id 7 = AVC.
    static func videoHeader(isKeyFrame: Bool) -> UInt8 {
        ((isKeyFrame ? 1 : 2) << 4) | 7
    }

    // MARK: - AudioSpecificConfig

    /// AAC sample rates in `AudioSpecificConfig` order, the same table the
    /// demuxer uses for ADTS.
    private static let sampleRates = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000,
        22050, 16000, 12000, 11025, 8000, 7350,
    ]

    /// Channel count from the four config bits, before the padding.
    public static func channels(ofAudioSpecificConfig config: Data) -> Int {
        guard config.count >= 2 else { return 1 }
        let value = (Int(config[config.startIndex]) << 8) | Int(config[config.startIndex + 1])
        let channels = (value >> 3) & 0x0F
        return max(1, channels)
    }

    /// Sample rate from the frequency index, or 0 when it does not map.
    public static func sampleRate(ofAudioSpecificConfig config: Data) -> Int {
        guard config.count >= 2 else { return 0 }
        let value = (Int(config[config.startIndex]) << 8) | Int(config[config.startIndex + 1])
        let index = (value >> 7) & 0x0F
        guard index < sampleRates.count else { return 0 }
        return sampleRates[index]
    }
}
