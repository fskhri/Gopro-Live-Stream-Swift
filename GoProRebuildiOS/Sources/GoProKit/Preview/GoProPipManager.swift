import AVFoundation
import Foundation

#if canImport(AVKit) && os(iOS)
import AVKit
import Combine

/// Manages Picture-in-Picture for the GoPro live preview player.
///
/// Keeps video playback, background execution, and network pipes active while
/// the user switches to other apps (e.g. TikTok) or interacts with chat.
public final class GoProPipManager: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private var _isPipActive = false
    private var _isPipPossible = false

    public var isPipActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPipActive
    }

    public var isPipPossible: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPipPossible
    }

    private var pipController: AVPictureInPictureController?
    private weak var currentLayer: AVSampleBufferDisplayLayer?
    private var pipPossibleObservation: NSKeyValueObservation?

    public override init() {
        super.init()
    }

    /// Attaches Picture-in-Picture to a sample buffer display layer.
    @MainActor
    public func attach(to layer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        // If already attached to this layer, do not recreate controller
        if currentLayer === layer, pipController != nil { return }
        currentLayer = layer

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller
        
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            guard let self else { return }
            self.stateLock.lock()
            let changed = self._isPipPossible != controller.isPictureInPicturePossible
            self._isPipPossible = controller.isPictureInPicturePossible
            self.stateLock.unlock()
            if changed {
                Task { @MainActor in
                    self.objectWillChange.send()
                }
            }
        }
        
        stateLock.lock()
        self._isPipPossible = controller.isPictureInPicturePossible
        stateLock.unlock()
        objectWillChange.send()
    }

    @MainActor
    public func startPip() {
        guard let controller = pipController, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    @MainActor
    public func stopPip() {
        pipController?.stopPictureInPicture()
    }

    @MainActor
    public func togglePip() {
        if isPipActive {
            stopPip()
        } else {
            startPip()
        }
    }

    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Stream is live: continue presentation
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Indefinite/infinite range marks live broadcast to iOS PiP UI
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    public func pictureInPictureControllerIsPlaybackLikelyToKeepUp(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        true
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval additionalTime: CMTime
    ) async {}

    // MARK: - AVPictureInPictureControllerDelegate

    public func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        stateLock.lock()
        _isPipActive = true
        stateLock.unlock()
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    public func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        stateLock.lock()
        _isPipActive = false
        stateLock.unlock()
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        stateLock.lock()
        _isPipActive = false
        stateLock.unlock()
        Task { @MainActor in
            self.objectWillChange.send()
        }
    }
}
#else
public final class GoProPipManager: NSObject, ObservableObject, @unchecked Sendable {
    public var isPipActive: Bool { false }
    public var isPipPossible: Bool { false }
    public override init() { super.init() }
    public func attach(to layer: AVSampleBufferDisplayLayer) {}
    public func startPip() {}
    public func stopPip() {}
    public func togglePip() {}
}
#endif
