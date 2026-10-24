import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// H.264 decoder for the preview stream.
///
/// Port of what `ExoPlayer` did on Android with its own H.264 renderer. The
/// camera sends Annex-B elementary stream; this type turns the AVCC access
/// units the demuxer produces into decoded pixel buffers.
///
/// Output is pixel buffers rather than a display layer, so the decoder stays
/// usable for offline tests and for a future recording path.
///
/// Not thread-safe. Feed it from one queue and read `onFrame` there.
public final class GoProH264Decoder {
    public enum DecoderError: Error, LocalizedError {
        case invalidParameterSets
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case sessionCreationFailed(OSStatus)
        case decodeFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .invalidParameterSets:
                return "The camera sent parameter sets this decoder cannot use."
            case .blockBufferFailed(let status):
                return "Could not build a frame buffer (status \(status))."
            case .sampleBufferFailed(let status):
                return "Could not wrap a frame (status \(status))."
            case .sessionCreationFailed(let status):
                return "The video decoder could not start (status \(status))."
            case .decodeFailed(let status):
                return "The video decoder rejected a frame (status \(status))."
            }
        }
    }

    /// Decoded output, delivered on the decoder's queue.
    public var onFrame: ((CVPixelBuffer, CMTime, CMTime, Bool) -> Void)?

    public var isConfigured: Bool {
        lock.lock()
        defer { lock.unlock() }
        return formatDescription != nil
    }

    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var parameterSetsKey: String?

    /// Non-key frames before the first key frame cannot be decoded; they are
    /// dropped until the stream has caught up.
    private var waitingForKeyFrame = true
    private var decodedFrameCount = 0
    private var droppedFrameCount = 0

    public init() {}

    /// Frame counters, safe to read while the decoder is running.
    public var statistics: (decoded: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (decodedFrameCount, droppedFrameCount)
    }

    /// Install new SPS/PPS. A new session is only built when they actually
    /// change, which keeps the camera's repeated parameter sets free.
    public func configure(sps: Data, pps: Data) throws {
        let key = "\(sps.count)-\(pps.count)-\(sps.hashValue)-\(pps.hashValue)"
        lock.lock()
        let unchanged = key == parameterSetsKey
        lock.unlock()
        guard !unchanged else { return }

        let description: CMVideoFormatDescription
        do {
            description = try Self.makeFormatDescription(sps: sps, pps: pps)
        } catch {
            throw DecoderError.invalidParameterSets
        }

        let destinationPixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            throw DecoderError.sessionCreationFailed(status)
        }
        // Real-time decoding keeps the decoder from buffering ahead of the
        // network, which would add latency to a live preview.
        VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        lock.lock()
        let previous = session
        session = newSession
        formatDescription = description
        parameterSetsKey = key
        waitingForKeyFrame = true
        lock.unlock()

        if let previous {
            VTDecompressionSessionInvalidate(previous)
        }
    }

    /// Decode one picture.
    ///
    /// - Returns: `false` when the frame was dropped instead of decoded.
    @discardableResult
    public func decode(_ unit: GoProAccessUnit) -> Bool {
        lock.lock()
        let description = formatDescription
        let session = session
        let needsKeyFrame = waitingForKeyFrame
        lock.unlock()

        // Without a key frame there is no complete picture to start from.
        guard !needsKeyFrame || unit.isKeyFrame else {
            lock.lock()
            droppedFrameCount += 1
            lock.unlock()
            return false
        }

        guard let description, let session else {
            lock.lock()
            droppedFrameCount += 1
            lock.unlock()
            return false
        }

        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try Self.makeSampleBuffer(
                avccData: unit.avccData,
                formatDescription: description,
                presentationTime: unit.presentationTime,
                decodeTime: unit.decodeTime
            )
        } catch {
            lock.lock()
            droppedFrameCount += 1
            lock.unlock()
            return false
        }

        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, presentationTime, duration in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }
            self?.recordFrame(pixelBuffer, presentationTime, duration, isKeyFrame: unit.isKeyFrame)
        }

        guard status == noErr else {
            lock.lock()
            droppedFrameCount += 1
            lock.unlock()

            // A fatal status means the session must be rebuilt from the next
            // parameter sets; drop it now so decoding restarts cleanly.
            if status == kVTInvalidSessionErr || status == kVTCouldNotFindVideoDecoderErr {
                lock.lock()
                let dead = self.session
                self.session = nil
                self.formatDescription = nil
                self.parameterSetsKey = nil
                lock.unlock()
                if let dead {
                    VTDecompressionSessionInvalidate(dead)
                }
            }
            return false
        }

        if unit.isKeyFrame {
            lock.lock()
            waitingForKeyFrame = false
            lock.unlock()
        }
        return true
    }

    /// Block until frames the decoder is still working on have been produced.
    public func finish() {
        lock.lock()
        let session = session
        lock.unlock()
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    public func reset() {
        finish()

        lock.lock()
        let session = self.session
        self.session = nil
        formatDescription = nil
        parameterSetsKey = nil
        waitingForKeyFrame = true
        lock.unlock()

        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Discard buffered state and wait for the next key frame, keeping the
    /// existing decoder session.
    public func forceKeyFrame() {
        lock.lock()
        waitingForKeyFrame = true
        lock.unlock()
    }

    /// Decode callback, which VideoToolbox runs on its own thread.
    private func recordFrame(
        _ pixelBuffer: CVPixelBuffer,
        _ presentationTime: CMTime,
        _ duration: CMTime,
        isKeyFrame: Bool
    ) {
        lock.lock()
        decodedFrameCount += 1
        waitingForKeyFrame = false
        lock.unlock()

        onFrame?(pixelBuffer, presentationTime, duration, isKeyFrame)
    }

    // MARK: - Sample construction

    static func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?

        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress
                else { return kCVReturnInvalidArgument }

                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }

        guard status == noErr, let description else { throw DecoderError.invalidParameterSets }
        return description
    }

    static func makeSampleBuffer(
        avccData: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTime: Double,
        decodeTime: Double
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let length = avccData.count

        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard created == kCMBlockBufferNoErr, let blockBuffer else {
            throw DecoderError.blockBufferFailed(created)
        }

        let copied: OSStatus = avccData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else {
            throw DecoderError.blockBufferFailed(copied)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue((presentationTime * 90_000).rounded()), timescale: 90_000),
            decodeTimeStamp: CMTime(value: CMTimeValue((decodeTime * 90_000).rounded()), timescale: 90_000)
        )
        var sampleSize = length

        var sampleBuffer: CMSampleBuffer?
        let ready = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard ready == noErr, let sampleBuffer else {
            throw DecoderError.sampleBufferFailed(ready)
        }
        return sampleBuffer
    }
}
