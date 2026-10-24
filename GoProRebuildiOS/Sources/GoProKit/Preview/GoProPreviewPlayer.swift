import AVFoundation
import CoreMedia
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Plays the camera's live preview.
///
/// Replaces `media/PreviewPlayer.kt` and `media/PreviewPlayerView.kt`. On
/// Android, ExoPlayer consumed a `MediaSource` built from the UDP URL; here the
/// pieces are wired by hand: the camera is told to start, the UDP datagrams are
/// stripped and demuxed, and the H.264 access units are decoded with
/// VideoToolbox into the display layer.
///
/// The player owns the `AVSampleBufferDisplayLayer`. The app puts it on screen
/// with `GoProPreviewSurface`.
///
/// State is published on the main queue, the only place the app reads it from.
///
/// Not thread-safe on its own: `start()` and `stop()` must not overlap. The
/// demuxer and decoder are used only from the stream consumer task.
public final class GoProPreviewPlayer: ObservableObject, @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// The camera has been asked to stream but has not sent video yet.
        case waitingForCamera
        case streaming
        case failed(String)
    }

    public struct Statistics: Equatable, Sendable {
        public var datagrams: Int = 0
        public var accessUnits: Int = 0
        public var decodedFrames: Int = 0
        public var droppedFrames: Int = 0
        public var presentedFrames: Int = 0
        /// AAC frames demuxed. The preview does not play them; the live
        /// streamer is the consumer that muxes them.
        public var audioFrames: Int = 0
    }

    /// Frames the camera may still be quiet for before the player gives up.
    public static let firstFrameTimeout: TimeInterval = 12

    @Published public private(set) var displayLayer: AVSampleBufferDisplayLayer
    public let pipManager = GoProPipManager()

    @Published public private(set) var state: State = .idle

    private let api: GoProWifiAPI
    private let receiver: GoProUdpReceiver
    private let keepAlive: GoProStreamKeepAlive
    private let demuxer = GoProTsDemuxer()
    private let decoder = GoProH264Decoder()

    private let lock = NSLock()
    private var statisticsStore = Statistics()
    private var consumer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var needsFlush = false
    private var isAppInBackground = false

    /// Extra consumers of the demuxed stream, keyed by a caller-chosen id.
    ///
    /// The live streamer is the only one today: it needs the same access units
    /// and parameter sets the preview decodes. A second `GoProUdpReceiver` on
    /// the same port would split the datagrams between two sockets, so the
    /// stream is fanned out instead.
    private var observers: [UUID: @Sendable (GoProDemuxEvent) -> Void] = [:]

    public init(
        api: GoProWifiAPI,
        host: String = GoProPreviewConfiguration.cameraHost,
        port: UInt16 = GoProPreviewConfiguration.streamPort
    ) {
        self.api = api
        self.receiver = GoProUdpReceiver(port: port)
        self.keepAlive = GoProStreamKeepAlive(host: host, port: port)
        self.displayLayer = AVSampleBufferDisplayLayer()
        // Fit the stream's frame inside the room the screen gives it instead of
        // cropping it.
        self.displayLayer.videoGravity = .resizeAspect
        Self.configureTimebase(for: self.displayLayer)

        #if os(iOS)
        let initialLayer = self.displayLayer
        Task { @MainActor in
            self.pipManager.attach(to: initialLayer)
        }
        #endif

        decoder.onFrame = { [weak self] pixelBuffer, presentationTime, duration, isKeyFrame in
            self?.present(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                isKeyFrame: isKeyFrame
            )
        }

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isAppInBackground = true
            self.lock.unlock()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.isAppInBackground = false
            self.lock.unlock()
            self.recreateDisplayLayer()
            if self.state == .streaming || self.state == .waitingForCamera {
                Task {
                    try? await self.api.startPreview()
                }
            }
        }
        #endif
    }

    /// Replaces the current display layer with a fresh instance.
    ///
    /// Required when returning from the background or recovering from an
    /// `AVSampleBufferDisplayLayer` failure.
    public func recreateDisplayLayer() {
        #if os(iOS)
        if pipManager.isPipActive { return }
        #endif

        lock.lock()
        let oldLayer = self.displayLayer
        let newLayer = AVSampleBufferDisplayLayer()
        newLayer.videoGravity = .resizeAspect
        Self.configureTimebase(for: newLayer)
        self.displayLayer = newLayer
        lock.unlock()

        Task { @MainActor in
            oldLayer.flushAndRemoveImage()
            oldLayer.removeFromSuperlayer()
            #if os(iOS)
            self.pipManager.attach(to: newLayer)
            #endif
            self.objectWillChange.send()
        }
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statisticsStore
    }

    // MARK: - Lifecycle

    /// Ask the camera to stream and start playing it.
    ///
    /// - Throws: the camera's preview command failing, or the socket refusing
    ///   to bind. Nothing is left running when it throws.
    public func start() async throws {
        await stop(notifyCamera: false)

        if displayLayer.status == .failed {
            recreateDisplayLayer()
        } else {
            displayLayer.flushAndRemoveImage()
        }
        demuxer.reset()
        decoder.reset()
        resetStatistics()
        setState(.waitingForCamera)

        do {
            try await api.startPreview()
        } catch {
            setState(.failed("Could not start the preview stream. \(error.localizedDescription)"))
            throw error
        }

        let stream: AsyncStream<Data>
        do {
            stream = try receiver.start()
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }

        keepAlive.start()

        let consumer = Task.detached(priority: .userInitiated) { [weak self] in
            for await datagram in stream {
                self?.consume(datagram)
            }
        }
        setConsumer(consumer)

        startWatchdog()
    }

    /// Stop streaming and ask the camera to stop as well.
    public func stop() async {
        await stop(notifyCamera: true)
    }

    private func stop(notifyCamera: Bool) async {
        let tasks = takeRunningTasks()

        tasks.watchdog?.cancel()
        tasks.consumer?.cancel()
        receiver.stop()
        keepAlive.stop()

        // Waiting for the consumer guarantees the demuxer and decoder are idle
        // before they are reset below.
        _ = await tasks.consumer?.value

        decoder.reset()
        demuxer.reset()
        displayLayer.flushAndRemoveImage()

        if notifyCamera {
            // The camera stops streaming on its own when the socket closes, but
            // the explicit stop keeps it from pushing into a dead port.
            try? await api.stopPreview()
        }

        setState(.idle)
    }

    /// Drop everything received so far and re-sync on the next key frame.
    ///
    /// The flag is picked up by the stream consumer, so the demuxer and decoder
    /// are only ever touched by the thread that owns them.
    public func flush() {
        lock.lock()
        needsFlush = true
        lock.unlock()
    }

    // MARK: - Fan-out

    /// Subscribe to every demuxed event, including audio.
    ///
    public var currentParameterSets: (sps: Data, pps: Data)? {
        lock.lock()
        defer { lock.unlock() }
        return demuxer.currentParameterSets
    }

    /// The handler runs on the stream consumer's thread, in stream order, and
    /// must return quickly: it is on the path that feeds the decoder. The
    /// returned id unsubscribes through `removeDemuxObserver(_:)`.
    @discardableResult
    public func addDemuxObserver(_ handler: @escaping @Sendable (GoProDemuxEvent) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        let cached = demuxer.currentParameterSets
        lock.unlock()
        if let cached {
            handler(.parameterSets(sps: cached.sps, pps: cached.pps))
        }
        return id
    }

    public func removeDemuxObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    private func notifyObservers(_ event: GoProDemuxEvent) {
        lock.lock()
        let handlers = Array(observers.values)
        lock.unlock()
        for handler in handlers {
            handler(event)
        }
    }

    // MARK: - Streaming

    private func consume(_ datagram: Data) {
        if takePendingFlush() {
            demuxer.reset()
            decoder.reset()
            displayLayer.flushAndRemoveImage()
        }

        guard let payload = try? GoProDatagramStripper.strip(datagram).payload else { return }

        lock.lock()
        statisticsStore.datagrams += 1
        lock.unlock()

        for event in demuxer.feed(payload) {
            switch event {
            case .parameterSets(let sps, let pps):
                try? decoder.configure(sps: sps, pps: pps)
            case .accessUnit(let unit):
                incrementAccessUnits()
                decoder.decode(unit)
            case .audioFrame:
                // The preview plays no sound. The demux event is still handed
                // to `onDemuxEvent`, the live streamer is the consumer that
                // muxes it.
                lock.lock()
                statisticsStore.audioFrames += 1
                lock.unlock()
            }
            notifyObservers(event)
        }
    }

    private func present(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        isKeyFrame: Bool
    ) {
        lock.lock()
        let inBackground = isAppInBackground && !pipManager.isPipActive
        lock.unlock()
        guard !inBackground else { return }

        guard let sampleBuffer = Self.makeDisplaySampleBuffer(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            duration: duration
        ) else { return }

        if displayLayer.status == .failed {
            recreateDisplayLayer()
            return
        }

        // The layer is only ready when it has room, so dropping inter frames
        // while it catches up is cheaper than queueing stale video.
        if !displayLayer.isReadyForMoreMediaData, !isKeyFrame {
            lock.lock()
            statisticsStore.droppedFrames += 1
            lock.unlock()
            return
        }

        displayLayer.enqueue(sampleBuffer)

        lock.lock()
        statisticsStore.presentedFrames += 1
        let isFirstFrame = statisticsStore.presentedFrames == 1
        lock.unlock()

        if isFirstFrame {
            setState(.streaming)
        }
    }

    private func startWatchdog() {
        let timeout = Self.firstFrameTimeout
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.presentedFrameCount == 0 else { return }
            self.setState(.failed(
                "No video arrived from the camera. Check that the phone is on the camera's Wi-Fi."
            ))
        }
        lock.lock()
        watchdog = task
        lock.unlock()
    }

    private var presentedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return statisticsStore.presentedFrames
    }

    // MARK: - State helpers
    //
    // These stay synchronous so `start()` and `stop()` never take the lock from
    // an asynchronous context, which Swift 6 rejects.

    private func setConsumer(_ task: Task<Void, Never>) {
        lock.lock()
        consumer = task
        lock.unlock()
    }

    private func takeRunningTasks() -> (consumer: Task<Void, Never>?, watchdog: Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        let tasks = (consumer, watchdog)
        consumer = nil
        watchdog = nil
        return tasks
    }

    private func resetStatistics() {
        lock.lock()
        statisticsStore = Statistics()
        lock.unlock()
    }

    private func incrementAccessUnits() {
        lock.lock()
        statisticsStore.accessUnits += 1
        lock.unlock()
    }

    private func takePendingFlush() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let pending = needsFlush
        needsFlush = false
        return pending
    }

    /// Publish a state change on the main queue, which is where `@Published` is
    /// allowed to fire and where SwiftUI reads it.
    private func setState(_ newState: State) {
        if Thread.isMainThread {
            applyState(newState)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.applyState(newState)
            }
        }
    }

    private func applyState(_ newState: State) {
        guard state != newState else { return }
        state = newState
    }

    // MARK: - Display

    private static func configureTimebase(for layer: AVSampleBufferDisplayLayer) {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if status == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            layer.controlTimebase = timebase
        }
    }

    static func makeDisplaySampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let ready = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard ready == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }
}
