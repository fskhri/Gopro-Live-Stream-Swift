import Foundation

/// One decoded picture worth of H.264, in AVCC form.
///
/// `avccData` holds each NAL unit prefixed by a 4-byte big-endian length, the
/// layout `VTDecompressionSession` consumes. Annex-B start codes are removed.
public struct GoProAccessUnit: Equatable, Sendable {
    public let avccData: Data
    public let isKeyFrame: Bool
    /// Seconds, taken from the PES presentation timestamp when present.
    public let presentationTime: Double
    /// Seconds, taken from the PES decode timestamp, or the PTS when absent.
    public let decodeTime: Double

    public init(
        avccData: Data,
        isKeyFrame: Bool,
        presentationTime: Double,
        decodeTime: Double
    ) {
        self.avccData = avccData
        self.isKeyFrame = isKeyFrame
        self.presentationTime = presentationTime
        self.decodeTime = decodeTime
    }
}

/// One AAC frame, with its ADTS headers stripped.
///
/// `stream_type 0x0F` means the payload is already framed as ADTS, so the
/// access unit and the decoder configuration can both be recovered from the
/// header without decoding anything.
public struct GoProAudioFrame: Equatable, Sendable {
    /// AAC frame bytes with the ADTS header removed, what FLV/AVCC want.
    public let aacData: Data
    /// Seconds, from the PES presentation timestamp when present.
    public let presentationTime: Double
    /// Two-byte `AudioSpecificConfig` built from the ADTS header.
    public let audioSpecificConfig: Data

    public init(aacData: Data, presentationTime: Double, audioSpecificConfig: Data) {
        self.aacData = aacData
        self.presentationTime = presentationTime
        self.audioSpecificConfig = audioSpecificConfig
    }
}

/// Everything the demuxer produces: parameter sets for the decoder, then frames.
public enum GoProDemuxEvent: Equatable, Sendable {
    /// SPS/PPS pair, emitted when it changes. A decoder must be configured
    /// with these before it can decode any following access unit.
    case parameterSets(sps: Data, pps: Data)
    case accessUnit(GoProAccessUnit)
    /// One AAC frame from the camera's microphone track, when the PMT
    /// declares one.
    case audioFrame(GoProAudioFrame)
}

/// MPEG-TS demuxer for the GoPro live preview stream.
///
/// Port of the pieces `ExoPlayer` handled on Android: `TsExtractor` for
/// transport-stream parsing and `GoProTsExtractorFactory` for the one
/// GoPro-specific rule. The camera declares a private stream with
/// `stream_type 0x80` on a PID that never carries payload; Android had to drop
/// it or the prepare loop could never complete. Here it is simply never matched
/// as video, which produces the same result.
///
/// Pure Swift, no AVFoundation dependency: the demuxer is unit-testable
/// without a decoder or a camera.
///
/// Not thread-safe. Feed it from one queue only.
public final class GoProTsDemuxer {
    public struct Statistics: Equatable, Sendable {
        /// TS packets dropped after a continuity-counter mismatch.
        public var droppedPackets: Int = 0
        /// Continuity-counter mismatches seen on any PID.
        public var discontinuities: Int = 0
        /// Packets seen on the video PID.
        public var videoPackets: Int = 0
        /// Packets seen on the audio PID.
        public var audioPackets: Int = 0
        /// PAT sections seen.
        public var programsFound: Int = 0
    }

    public private(set) var statistics = Statistics()

    /// Video elementary-stream PID, `nil` until a PMT has been read.
    public var videoPID: Int? { videoPIDValue }

    /// Audio elementary-stream PID, `nil` when the PMT declares no AAC track.
    public var audioPID: Int? { audioPIDValue }

    private let packetSize = GoProPreviewConfiguration.transportStreamPacketSize
    private let syncByte = GoProPreviewConfiguration.syncByte

    private var buffer = Data()
    private var pmtPID: Int?
    private var videoPIDValue: Int?
    private var audioPIDValue: Int?
    private var lastContinuity: [Int: UInt8] = [:]

    // MARK: PES assembly

    private var pesES = Data()
    private var pesHeaderParsed = true
    private var pesPTS: Double?
    private var pesDTS: Double?
    /// Set when a TS packet was lost mid-PES: everything until the next
    /// payload-unit-start belongs to a picture whose first bytes are gone.
    private var discardUntilNextStart = false

    // MARK: Audio PES assembly

    /// Audio PES packets are collected separately: they complete on the next
    /// payload-unit-start rather than on a picture delimiter.
    private var audioES = Data()
    private var audioHeaderParsed = true
    private var audioPTS: Double?
    private var audioCarry = Data()
    private var lastAudioSpecificConfig: Data?

    // MARK: Access-unit assembly

    private var pendingNALs: [Data] = []
    private var pendingIsKeyFrame = false
    private var pendingPTS: Double = 0
    private var pendingDTS: Double = 0
    private var hasVideoNAL = false

    private var sps: Data?
    private var pps: Data?
    private var lastEmittedSPS: Data?
    private var lastEmittedPPS: Data?

    // MARK: Timestamps

    private var lastPresentationTime: Double?
    private var syntheticFrameIndex = 0
    /// Running audio clock, used for frames whose PES carries no timestamp.
    private var lastAudioTime: Double = 0

    public init() {}

    /// Drop all partial state, for example when preview stops and restarts.
    public func reset() {
        buffer.removeAll(keepingCapacity: false)
        pmtPID = nil
        videoPIDValue = nil
        audioPIDValue = nil
        lastContinuity.removeAll(keepingCapacity: false)

        pesES.removeAll(keepingCapacity: false)
        pesHeaderParsed = true
        pesPTS = nil
        pesDTS = nil
        discardUntilNextStart = false

        audioES.removeAll(keepingCapacity: false)
        audioHeaderParsed = true
        audioPTS = nil
        audioCarry.removeAll(keepingCapacity: false)
        lastAudioSpecificConfig = nil

        pendingNALs.removeAll(keepingCapacity: false)
        pendingIsKeyFrame = false
        hasVideoNAL = false

        sps = nil
        pps = nil
        lastEmittedSPS = nil
        lastEmittedPPS = nil

        lastPresentationTime = nil
        syntheticFrameIndex = 0
        lastAudioTime = 0
    }

    /// Feed MPEG-TS bytes, in any chunk size.
    ///
    /// - Returns: zero or more events. An access unit completes when the next
    ///   frame delimiter arrives, so the final frame of a stream is held back
    ///   until `flush()` is called.
    public func feed(_ data: Data) -> [GoProDemuxEvent] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var events: [GoProDemuxEvent] = []
        while buffer.count >= packetSize {
            guard buffer[buffer.startIndex] == syncByte else {
                resynchronize()
                continue
            }
            let packet = Data(buffer.prefix(packetSize))
            buffer.removeFirst(packetSize)
            process(packet: packet, into: &events)
        }
        return events
    }

    /// Emit the access unit still being assembled, if any.
    public func flush() -> [GoProDemuxEvent] {
        var events: [GoProDemuxEvent] = []
        flushPES(into: &events)
        flushAccessUnit(into: &events)
        flushAudioPES(into: &events)
        return events
    }

    // MARK: - Transport stream

    /// Skip forward to the next plausible sync byte after a desync.
    private func resynchronize() {
        var skipped = 0
        while !buffer.isEmpty, buffer[buffer.startIndex] != syncByte {
            buffer.removeFirst()
            skipped += 1
        }
        if skipped > 0 {
            statistics.discontinuities += 1
            statistics.droppedPackets += max(1, skipped / packetSize)
        }
    }

    private func process(packet: Data, into events: inout [GoProDemuxEvent]) {
        let start = packet.startIndex
        let pid = (Int(packet[start + 1] & 0x1F) << 8) | Int(packet[start + 2])
        let payloadUnitStart = packet[start + 1] & 0x40 != 0
        let adaptationControl = (packet[start + 3] >> 4) & 0x03
        let continuity = packet[start + 3] & 0x0F

        // 0x00 is reserved, 0x02 carries an adaptation field and no payload.
        guard adaptationControl == 0x01 || adaptationControl == 0x03 else { return }

        var payloadIndex = start + 4
        if adaptationControl == 0x03 {
            let adaptationLength = Int(packet[start + 4])
            payloadIndex = start + 5 + adaptationLength
        }
        guard payloadIndex < packet.endIndex else { return }

        if !checkContinuity(pid: pid, continuity: continuity) {
            if pid == videoPIDValue {
                // A packet went missing, so the PES in progress is incomplete
                // and its bytes cannot form a picture. Salvage nothing: a PES
                // that already started is discarded whole, and the next PES
                // only starts cleanly at its own payload-unit-start packet.
                if payloadUnitStart, !discardUntilNextStart {
                    flushPES(into: &events)
                }
                pesES.removeAll(keepingCapacity: true)
                pesHeaderParsed = true
                discardUntilNextStart = true
            }
            return
        }

        let payload = packet[payloadIndex...]

        if pid == 0 {
            if let section = extractSection(payload, payloadUnitStart: payloadUnitStart) {
                parsePAT(section)
            }
            return
        }
        if let pmtPID, pid == pmtPID {
            if let section = extractSection(payload, payloadUnitStart: payloadUnitStart) {
                parsePMT(section)
            }
            return
        }
        if let videoPIDValue, pid == videoPIDValue {
            if discardUntilNextStart {
                // A PES was lost mid-stream; wait for the next complete one.
                guard payloadUnitStart else { return }
                discardUntilNextStart = false
            }
            processVideoPayload(payload, payloadUnitStart: payloadUnitStart, into: &events)
            return
        }
        if let audioPIDValue, pid == audioPIDValue {
            processAudioPayload(payload, payloadUnitStart: payloadUnitStart, into: &events)
        }
    }

    /// - Returns: `false` when the packet is a duplicate or breaks the sequence.
    private func checkContinuity(pid: Int, continuity: UInt8) -> Bool {
        guard let previous = lastContinuity[pid] else {
            lastContinuity[pid] = continuity
            return true
        }
        lastContinuity[pid] = continuity
        guard continuity != previous else {
            // A retransmitted packet carries no new bytes.
            return false
        }
        let expected = previous == 0x0F ? 0 : previous &+ 1
        guard continuity == expected else {
            statistics.discontinuities += 1
            statistics.droppedPackets += 1
            return false
        }
        return true
    }

    /// PSI sections arrive with a pointer field before the table.
    private func extractSection(_ payload: Data, payloadUnitStart: Bool) -> Data? {
        guard payloadUnitStart, payload.count > 1 else { return nil }
        let pointer = Int(payload[payload.startIndex])
        let sectionStart = payload.startIndex + 1 + pointer
        guard sectionStart < payload.endIndex else { return nil }
        return Data(payload[sectionStart...])
    }

    private func parsePAT(_ section: Data) {
        let start = section.startIndex
        guard section.count >= 12, section[start] == 0x00 else { return }
        let length = ((Int(section[start + 1] & 0x0F)) << 8) | Int(section[start + 2])
        let end = min(start + 3 + length, section.endIndex)

        // Entries begin after the 5-byte header that follows the section header.
        var index = start + 8
        while index + 4 <= end {
            let programNumber = (Int(section[index]) << 8) | Int(section[index + 1])
            let pid = (Int(section[index + 2] & 0x1F) << 8) | Int(section[index + 3])
            // Program 0 is the network information table, not a PMT.
            if programNumber != 0, pmtPID == nil || pmtPID == pid {
                pmtPID = pid
                statistics.programsFound += 1
            }
            index += 4
        }
    }

    private func parsePMT(_ section: Data) {
        let start = section.startIndex
        guard section.count >= 12, section[start] == 0x02 else { return }
        let length = ((Int(section[start + 1] & 0x0F)) << 8) | Int(section[start + 2])
        let end = min(start + 3 + length, section.endIndex)

        let programInfoLength = ((Int(section[start + 10] & 0x0F)) << 8) | Int(section[start + 11])
        var index = start + 12 + programInfoLength

        while index + 5 <= end {
            let streamType = section[index]
            let pid = (Int(section[index + 1] & 0x1F) << 8) | Int(section[index + 2])
            let esInfoLength = ((Int(section[index + 3] & 0x0F)) << 8) | Int(section[index + 4])

            // H.264 is taken as video; AAC (0x0F) as the mic track. stream_type
            // 0x80, the GoPro private stream that never carries payload, falls
            // through and is ignored.
            if streamType == GoProPreviewConfiguration.h264StreamType, videoPIDValue == nil {
                videoPIDValue = pid
            } else if streamType == GoProPreviewConfiguration.aacStreamType, audioPIDValue == nil {
                audioPIDValue = pid
            }
            index += 5 + esInfoLength
        }
    }

    // MARK: - Elementary stream

    private func processVideoPayload(_ payload: Data, payloadUnitStart: Bool, into events: inout [GoProDemuxEvent]) {
        statistics.videoPackets += 1

        var esBytes = payload
        if payloadUnitStart {
            flushPES(into: &events)
            if let offset = Self.pesStartOffset(in: payload) {
                esBytes = payload.dropFirst(offset)
            } else {
                esBytes = Data()
            }
            pesHeaderParsed = false
            pesPTS = nil
            pesDTS = nil
        }

        pesES.append(contentsOf: esBytes)
        parsePESHeaderIfNeeded()
    }

    /// Offset of the PES start code inside the first payload bytes of a packet.
    ///
    /// A PES packet starts with `00 00 01` straight away; a pointer field can
    /// still be sitting in front of it, the way PSI packets carry one. Scanning
    /// the first bytes makes both shapes parse, and a packet holding neither is
    /// dropped whole rather than fed to the header parser.
    static func pesStartOffset(in payload: Data) -> Int? {
        let last = min(payload.count - 3, 16)
        guard last >= 0 else { return nil }

        var index = 0
        while index <= last {
            let start = payload.startIndex + index
            if payload[start] == 0x00, payload[start + 1] == 0x00, payload[start + 2] == 0x01 {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Close the PES packet now in hand and turn its bytes into access units.
    private func flushPES(into events: inout [GoProDemuxEvent]) {
        defer {
            pesES.removeAll(keepingCapacity: true)
        }

        // An incomplete PES header means the packet never finished; drop it.
        guard pesHeaderParsed else { return }
        guard !pesES.isEmpty else { return }

        let es = pesES
        let pts = pesPTS
        let dts = pesDTS ?? pts
        self.pesPTS = nil
        self.pesDTS = nil

        for nal in Self.splitNALUnits(es) {
            handle(nal, pts: pts, dts: dts, into: &events)
        }
    }

    // MARK: - Audio elementary stream

    /// Audio PES handling runs independently of video: an AAC frame is bounded
    /// by its ADTS header rather than by a picture delimiter, so a lost packet
    /// only costs the frames it cut. The next sync word recovers the track.
    private func processAudioPayload(_ payload: Data, payloadUnitStart: Bool, into events: inout [GoProDemuxEvent]) {
        statistics.audioPackets += 1

        var esBytes = payload
        if payloadUnitStart {
            flushAudioPES(into: &events)
            if let offset = Self.pesStartOffset(in: payload) {
                esBytes = payload.dropFirst(offset)
            } else {
                esBytes = Data()
            }
            audioHeaderParsed = false
        }

        audioES.append(contentsOf: esBytes)
        parseAudioPESHeaderIfNeeded()
    }

    /// Same 9-byte PES header as video, minus the decode-timestamp handling.
    private func parseAudioPESHeaderIfNeeded() {
        guard !audioHeaderParsed else { return }
        let headerStart = 9
        guard audioES.count >= headerStart else { return }

        let start = audioES.startIndex
        guard audioES[start] == 0x00, audioES[start + 1] == 0x00, audioES[start + 2] == 0x01 else {
            audioHeaderParsed = true
            return
        }

        let flags = audioES[start + 6]
        let headerDataLength = Int(audioES[start + 8])
        guard flags & 0xC0 == 0x80 else {
            audioES.removeFirst(headerStart)
            audioHeaderParsed = true
            return
        }

        let totalLength = headerStart + headerDataLength
        guard audioES.count >= totalLength else { return }

        let flags2 = audioES[start + 7]
        if (flags2 >> 6) & 0x03 >= 0x02 {
            audioPTS = Self.timestamp(at: headerStart, in: audioES)
        }

        audioES.removeFirst(totalLength)
        audioHeaderParsed = true
    }

    private func flushAudioPES(into events: inout [GoProDemuxEvent]) {
        defer {
            audioES.removeAll(keepingCapacity: true)
            audioHeaderParsed = true
            audioPTS = nil
        }

        guard audioHeaderParsed else { return }

        var bytes = audioCarry
        audioCarry.removeAll(keepingCapacity: true)
        bytes.append(audioES)

        let pts = audioPTS
        var index = 0

        while let frame = Self.splitADTSFrame(from: bytes) {
            lastAudioSpecificConfig = frame.audioSpecificConfig
            let duration = frame.sampleRate > 0 ? 1024.0 / Double(frame.sampleRate) : 1.0 / 48_000.0
            // A PES carries one timestamp for several frames, so the per-frame
            // time is stepped forward by one frame of samples.
            let time = (pts ?? lastAudioTime) + Double(index) * duration

            events.append(.audioFrame(GoProAudioFrame(
                aacData: frame.payload,
                presentationTime: time,
                audioSpecificConfig: frame.audioSpecificConfig
            )))
            lastAudioTime = time + duration
            index += 1
            bytes = Data(bytes.dropFirst(frame.totalLength))
        }

        audioCarry = bytes
    }

    /// One ADTS frame, with its header fields already parsed.
    struct ADTSFrame {
        let header: Data
        let payload: Data
        let totalLength: Int
        let sampleRateIndex: Int
        /// `profile + 1` from the header, so 2 means AAC LC.
        let profile: Int
        let channels: Int

        /// Two-byte `AudioSpecificConfig` for an FLV AAC sequence header.
        var audioSpecificConfig: Data {
            GoProTsDemuxer.audioSpecificConfig(
                profile: profile,
                sampleRateIndex: sampleRateIndex,
                channels: channels
            ) ?? Data([0x12, 0x10])
        }

        var sampleRate: Int {
            GoProTsDemuxer.adtsSampleRates[sampleRateIndex]
        }
    }

    /// `96000 … 7350`, indexed by the four-bit field in the ADTS header.
    static let adtsSampleRates: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050,
        16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// Read the first complete ADTS frame in `data`, or `nil`.
    ///
    /// Scans for the 12-bit sync word, so a frame cut by a lost packet is
    /// skipped instead of decoded into noise.
    static func splitADTSFrame(from data: Data) -> ADTSFrame? {
        guard data.count >= 7 else { return nil }
        let bytes = [UInt8](data)

        var index = 0
        while index + 7 <= bytes.count {
            guard bytes[index] == 0xFF, bytes[index + 1] & 0xF0 == 0xF0 else {
                index += 1
                continue
            }

            // Layout: sync (12 bits), ID, layer, protection_absent,
            // profile, sampling_frequency_index, channel_configuration,
            // then the 13-bit frame length.
            let profileField = Int((bytes[index + 2] >> 6) & 0x03)
            let sampleRateIndex = Int((bytes[index + 2] >> 2) & 0x0F)
            let channels = (Int(bytes[index + 2] & 0x01) << 2) | (Int(bytes[index + 3] >> 6) & 0x03)
            let hasCRC = bytes[index + 1] & 0x01 == 0
            let headerLength = hasCRC ? 9 : 7
            let frameLength = (Int(bytes[index + 3] & 0x03) << 11)
                | (Int(bytes[index + 4]) << 3)
                | (Int(bytes[index + 5]) >> 5)

            guard sampleRateIndex < adtsSampleRates.count,
                  frameLength >= headerLength,
                  index + frameLength <= bytes.count else {
                index += 1
                continue
            }

            return ADTSFrame(
                header: Data(bytes[index..<index + headerLength]),
                payload: Data(bytes[(index + headerLength)..<index + frameLength]),
                totalLength: frameLength,
                sampleRateIndex: sampleRateIndex,
                profile: profileField + 1,
                channels: channels
            )
        }
        return nil
    }

    /// Two-byte `AudioSpecificConfig` from an ADTS header, what an FLV AAC
    /// sequence header carries.
    static func audioSpecificConfig(_ header: Data) -> Data? {
        guard header.count >= 4 else { return nil }
        let bytes = [UInt8](header)

        let profile = Int((bytes[2] >> 6) & 0x03) + 1
        let sampleRateIndex = Int((bytes[2] >> 2) & 0x0F)
        let channels = (Int(bytes[2] & 0x01) << 2) | (Int(bytes[3] >> 6) & 0x03)

        return audioSpecificConfig(profile: profile, sampleRateIndex: sampleRateIndex, channels: channels)
    }

    /// Pack the three fields an `AudioSpecificConfig` starts with.
    static func audioSpecificConfig(profile: Int, sampleRateIndex: Int, channels: Int) -> Data? {
        guard sampleRateIndex < adtsSampleRates.count, channels > 0 else { return nil }
        let bits = (profile << 11) | (sampleRateIndex << 7) | (channels << 3)
        return Data([UInt8((bits >> 8) & 0xFF), UInt8(bits & 0xFF)])
    }

    /// Strip the fixed 9-byte PES header plus its optional timestamps.
    ///
    /// Waits for more bytes when the header has not fully arrived yet, so a PES
    /// packet split across many TS packets is handled correctly.
    private func parsePESHeaderIfNeeded() {        guard !pesHeaderParsed else { return }
        let headerStart = 9
        guard pesES.count >= headerStart else { return }

        let start = pesES.startIndex
        guard pesES[start] == 0x00, pesES[start + 1] == 0x00, pesES[start + 2] == 0x01 else {
            // Not a PES header after all; treat the bytes as elementary stream.
            pesHeaderParsed = true
            return
        }

        let flags = pesES[start + 6]
        let flags2 = pesES[start + 7]
        let headerDataLength = Int(pesES[start + 8])
        guard flags & 0xC0 == 0x80 else {
            // stream_id 0xBE/0xBF/0xF0... have no optional header worth parsing.
            pesES.removeFirst(headerStart)
            pesHeaderParsed = true
            return
        }

        let totalLength = headerStart + headerDataLength
        guard pesES.count >= totalLength else { return }

        switch (flags2 >> 6) & 0x03 {
        case 0x02:
            pesPTS = Self.timestamp(at: headerStart, in: pesES)
        case 0x03:
            pesPTS = Self.timestamp(at: headerStart, in: pesES)
            pesDTS = Self.timestamp(at: headerStart + 5, in: pesES)
        default:
            break
        }

        pesES.removeFirst(totalLength)
        pesHeaderParsed = true
    }

    /// Decode the 33-bit timestamp packed into five PES bytes.
    static func timestamp(at offset: Int, in data: Data) -> Double {
        let base = data.startIndex + offset
        guard base + 5 <= data.endIndex else { return 0 }
        let b0 = Int(data[base])
        let b1 = Int(data[base + 1])
        let b2 = Int(data[base + 2])
        let b3 = Int(data[base + 3])
        let b4 = Int(data[base + 4])

        let ticks = ((b0 >> 1) & 0x07) << 30
            | b1 << 22
            | ((b2 >> 1) & 0x7F) << 15
            | b3 << 7
            | (b4 >> 1)
        return Double(ticks) / 90_000.0
    }

    private func handle(_ nal: Data, pts: Double?, dts: Double?, into events: inout [GoProDemuxEvent]) {
        guard let firstByte = nal.first else { return }
        let type = firstByte & 0x1F

        switch type {
        case 9:
            // Access unit delimiter: the previous picture ended.
            flushAccessUnit(into: &events)
        case 7:
            if hasVideoNAL { flushAccessUnit(into: &events) }
            append(nal, pts: pts, dts: dts)
            sps = nal
            maybeEmitParameterSets(into: &events)
        case 8:
            if hasVideoNAL { flushAccessUnit(into: &events) }
            append(nal, pts: pts, dts: dts)
            pps = nal
            maybeEmitParameterSets(into: &events)
        case 1, 5:
            if hasVideoNAL { flushAccessUnit(into: &events) }
            append(nal, pts: pts, dts: dts)
            hasVideoNAL = true
            if type == 5 { pendingIsKeyFrame = true }
        default:
            append(nal, pts: pts, dts: dts)
        }
    }

    private func append(_ nal: Data, pts: Double?, dts: Double?) {
        if pendingNALs.isEmpty {
            pendingPTS = resolvePresentationTime(pts)
            pendingDTS = dts.map { resolveDecodeTime($0, presentation: pendingPTS) } ?? pendingPTS
        }
        pendingNALs.append(nal)
    }

    private func flushAccessUnit(into events: inout [GoProDemuxEvent]) {
        defer {
            pendingNALs.removeAll(keepingCapacity: true)
            hasVideoNAL = false
            pendingIsKeyFrame = false
        }
        guard !pendingNALs.isEmpty else { return }

        var avcc = Data()
        for nal in pendingNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        events.append(.accessUnit(GoProAccessUnit(
            avccData: avcc,
            isKeyFrame: pendingIsKeyFrame,
            presentationTime: pendingPTS,
            decodeTime: pendingDTS
        )))
    }

    public var currentParameterSets: (sps: Data, pps: Data)? {
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }

    private func maybeEmitParameterSets(into events: inout [GoProDemuxEvent]) {
        guard let sps, let pps else { return }
        guard sps != lastEmittedSPS || pps != lastEmittedPPS else { return }
        lastEmittedSPS = sps
        lastEmittedPPS = pps
        events.append(.parameterSets(sps: sps, pps: pps))
    }

    /// Use the PES timestamp when the camera sends one, otherwise synthesize a
    /// 30 fps timeline so the renderer still has monotonic timing.
    private func resolvePresentationTime(_ pts: Double?) -> Double {
        if let pts {
            lastPresentationTime = pts
            syntheticFrameIndex = 0
            return pts
        }
        let fallback = lastPresentationTime.map { $0 + (1.0 / 30.0) } ?? 0
        lastPresentationTime = fallback
        syntheticFrameIndex += 1
        return fallback
    }

    private func resolveDecodeTime(_ dts: Double, presentation: Double) -> Double {
        dts <= presentation ? dts : presentation
    }

    // MARK: - NAL units

    /// Split Annex-B bytes into NAL units, without their start codes.
    ///
    /// Matches the rule `media3` applies on Android. A delimiter is either
    /// `00 00 01` or `00 00 00 01`; the scanner finds the three-byte form, so
    /// when the byte before it is also zero that byte is the extra zero of a
    /// four-byte delimiter and is given back to the delimiter instead of the
    /// preceding NAL.
    static func splitNALUnits(_ data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }

        let bytes = [UInt8](data)
        var units: [Data] = []
        var nalStart = -1

        var index = 0
        while index + 2 < bytes.count {
            guard bytes[index] == 0x00, bytes[index + 1] == 0x00, bytes[index + 2] == 0x01 else {
                index += 1
                continue
            }

            if nalStart >= 0 {
                let end = (index >= 1 && bytes[index - 1] == 0) ? index - 1 : index
                if end > nalStart { units.append(Data(bytes[nalStart..<end])) }
            }

            nalStart = index + 3
            index = nalStart
        }

        if nalStart >= 0, nalStart < bytes.count {
            units.append(Data(bytes[nalStart...]))
        }
        return units
    }
}
