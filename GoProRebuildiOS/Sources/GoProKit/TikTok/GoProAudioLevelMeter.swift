import AudioToolbox
import Foundation

/// Real-time peak volume meter for AAC audio packets.
///
/// Decodes incoming AAC frames to 16-bit PCM using `AudioConverter` and calculates
/// the peak amplitude normalized to `0.0 ... 1.0` with fast attack and exponential decay,
/// matching Android's `PreviewPlayer` / `MicrophoneStreamer` VU meter behavior.
public final class GoProAudioLevelMeter: @unchecked Sendable {
    private var converter: AudioConverterRef?
    private var pcmBuffer = [Int16](repeating: 0, count: 2048)
    private var lastLevel: Float = 0
    private let lock = NSLock()

    public init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        var inputDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var outputDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 2,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        AudioConverterNew(&inputDesc, &outputDesc, &converter)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    private final class Context {
        var data: UnsafeRawPointer
        var size: UInt32
        var packetDesc: UnsafeMutablePointer<AudioStreamPacketDescription>

        init(data: UnsafeRawPointer, size: UInt32) {
            self.data = data
            self.size = size
            self.packetDesc = .allocate(capacity: 1)
            self.packetDesc.initialize(to: AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: size
            ))
        }

        deinit {
            packetDesc.deallocate()
        }
    }

    /// Process an AAC frame payload and return the smoothed level in range `0.0 ... 1.0`.
    public func process(aacData: Data) -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, !aacData.isEmpty else { return 0 }

        var level = lastLevel
        aacData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let context = Context(data: base, size: UInt32(raw.count))
            let unmanaged = Unmanaged.passUnretained(context)

            var ioOutputDataPackets: UInt32 = 1024
            var bufferList = AudioBufferList()
            bufferList.mNumberBuffers = 1
            bufferList.mBuffers.mNumberChannels = 2
            bufferList.mBuffers.mDataByteSize = UInt32(pcmBuffer.count * MemoryLayout<Int16>.size)

            pcmBuffer.withUnsafeMutableBytes { pcmRaw in
                bufferList.mBuffers.mData = pcmRaw.baseAddress

                let status = AudioConverterFillComplexBuffer(
                    converter,
                    { (converter, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData) -> OSStatus in
                        guard let inUserData else { return -1 }
                        let ctx = Unmanaged<Context>.fromOpaque(inUserData).takeUnretainedValue()
                        guard ctx.size > 0 else {
                            ioNumberDataPackets.pointee = 0
                            return 0
                        }
                        ioNumberDataPackets.pointee = 1
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = 2
                        ioData.pointee.mBuffers.mDataByteSize = ctx.size
                        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ctx.data)
                        if let outDataPacketDescription {
                            outDataPacketDescription.pointee = ctx.packetDesc
                        }
                        ctx.size = 0
                        return 0
                    },
                    unmanaged.toOpaque(),
                    &ioOutputDataPackets,
                    &bufferList,
                    nil
                )

                if status == noErr, ioOutputDataPackets > 0 {
                    let samples = pcmRaw.bindMemory(to: Int16.self)
                    var maxPeak: Int16 = 0
                    let totalSamples = min(Int(ioOutputDataPackets * 2), samples.count)
                    for i in 0..<totalSamples {
                        let sample = abs(samples[i])
                        if sample > maxPeak { maxPeak = sample }
                    }
                    let normalized = min(max(Float(maxPeak) / 32767.0, 0), 1)
                    if normalized > lastLevel {
                        lastLevel = normalized
                    } else {
                        lastLevel = lastLevel * 0.7 + normalized * 0.3
                    }
                    level = lastLevel
                }
            }
        }
        return level
    }

    public func reset() {
        lock.lock()
        lastLevel = 0
        lock.unlock()
    }
}
