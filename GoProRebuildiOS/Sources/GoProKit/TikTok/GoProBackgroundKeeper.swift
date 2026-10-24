import AVFoundation
import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Keeps the app and its network connections (RTMP + UDP keepalive) alive in the background.
///
/// Uses an in-memory near-silent low-frequency audio loop with `AVAudioSession` category `.playback`,
/// `mode: .moviePlayback`, and `options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]`.
/// Also listens for audio interruptions (e.g. TikTok opening) and maintains a background execution
/// task assertion to ensure sockets and background threads are not suspended.
public final class GoProBackgroundKeeper: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private let lock = NSLock()
    private var isStarted = false

    #if canImport(UIKit) && !os(watchOS)
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif

    public override init() {
        super.init()
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotifications() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        #endif

        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
    }

    public func start() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true

        ensureAudioPlaying()
        #endif
    }

    public func stop() {
        #if os(iOS) || os(tvOS) || os(visionOS)
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        isStarted = false

        player?.stop()
        player = nil

        #if canImport(UIKit) && !os(watchOS)
        endBackgroundTask()
        #endif

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Internal Audio Lifecycle

    #if os(iOS) || os(tvOS) || os(visionOS)
    private func ensureAudioPlaying() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)

            if let existing = player {
                if !existing.isPlaying {
                    existing.play()
                }
            } else {
                let wavData = Self.makeInaudibleWav()
                let audioPlayer = try AVAudioPlayer(data: wavData)
                audioPlayer.delegate = self
                audioPlayer.numberOfLoops = -1
                audioPlayer.volume = 0.02
                audioPlayer.play()
                self.player = audioPlayer
            }
        } catch {
            #if DEBUG
            print("[BackgroundKeeper] Failed to configure audio playback: \(error)")
            #endif
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }

        if type == .began {
            #if canImport(UIKit) && !os(watchOS)
            beginBackgroundTask()
            #endif
        } else if type == .ended {
            ensureAudioPlaying()
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        ensureAudioPlaying()
    }
    #endif

    // MARK: - Background Task Lifecycle

    #if canImport(UIKit) && !os(watchOS)
    @objc private func appDidEnterBackground() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        beginBackgroundTask()
        ensureAudioPlaying()
    }

    @objc private func appWillEnterForeground() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        ensureAudioPlaying()
    }

    private func beginBackgroundTask() {
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "GoProStreamingBackground") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTaskId != .invalid else { return }
        let current = bgTaskId
        bgTaskId = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
    #endif

    // MARK: - WAV Generation

    /// Generates a 1-second 16kHz 16-bit PCM mono WAV file containing an inaudible 20Hz sine wave
    /// with amplitude 16 (out of 32767).
    ///
    /// Non-zero samples and non-zero volume ensure iOS audio routing recognizes active playback,
    /// while remaining completely inaudible to human ears.
    private static func makeInaudibleWav(durationSeconds: Double = 1.0, sampleRate: Int = 16000) -> Data {
        let numSamples = Int(Double(sampleRate) * durationSeconds)
        let byteRate = sampleRate * 2
        let dataChunkSize = numSamples * 2
        let fileSize = 36 + dataChunkSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        var u32 = UInt32(fileSize).littleEndian
        withUnsafeBytes(of: &u32) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        var fmtSize = UInt32(16).littleEndian
        withUnsafeBytes(of: &fmtSize) { data.append(contentsOf: $0) }
        var format = UInt16(1).littleEndian // PCM
        withUnsafeBytes(of: &format) { data.append(contentsOf: $0) }
        var channels = UInt16(1).littleEndian // Mono
        withUnsafeBytes(of: &channels) { data.append(contentsOf: $0) }
        var sRate = UInt32(sampleRate).littleEndian
        withUnsafeBytes(of: &sRate) { data.append(contentsOf: $0) }
        var bRate = UInt32(byteRate).littleEndian
        withUnsafeBytes(of: &bRate) { data.append(contentsOf: $0) }
        var blockAlign = UInt16(2).littleEndian
        withUnsafeBytes(of: &blockAlign) { data.append(contentsOf: $0) }
        var bitsPerSample = UInt16(16).littleEndian
        withUnsafeBytes(of: &bitsPerSample) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        var dSize = UInt32(dataChunkSize).littleEndian
        withUnsafeBytes(of: &dSize) { data.append(contentsOf: $0) }

        var pcmData = Data(capacity: dataChunkSize)
        for i in 0..<numSamples {
            let angle = 2.0 * Double.pi * 20.0 * Double(i) / Double(sampleRate)
            let sample = Int16(sin(angle) * 16.0).littleEndian
            withUnsafeBytes(of: sample) { pcmData.append(contentsOf: $0) }
        }
        data.append(pcmData)
        return data
    }
}
