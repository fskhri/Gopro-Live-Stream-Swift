import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Opens a TikTok LIVE room and pushes the preview stream into it.
///
/// Replaces `media/RtmpStreamer.kt` plus the push side of `GoProUdpRelay`. The
/// preview keeps the only UDP socket: frames arrive as demux events on a
/// subscriber, never by binding a second receiver, which would split the
/// datagrams between two sockets.
///
/// Each event is handed to a bounded queue, because the handler is called from
/// the stream consumer and must return immediately. The queue drains on the
/// main actor: the muxing itself is `GoProLiveMuxer`'s job, here it is only
/// turned into writes, which suspend.
///
/// `stop()` must not race `start()`. Both are driven from the control screen.
@MainActor
public final class GoProLiveStreamer: ObservableObject {
    /// What the caller wants the room opened with.
    public struct Options: Equatable, Sendable {
        public var title: String
        public var hashtagId: String
        public var gameTagId: String
        public var enableReplay: Bool
        public var regionPriority: String
        public var mature: Bool

        public init(
            title: String = "GoPro stream",
            hashtagId: String = GoProTikTokTopic.defaultHashtagId,
            gameTagId: String = "0",
            enableReplay: Bool = false,
            regionPriority: String = "id",
            mature: Bool = false
        ) {
            self.title = title
            self.hashtagId = hashtagId
            self.gameTagId = gameTagId
            self.enableReplay = enableReplay
            self.regionPriority = regionPriority
            self.mature = mature
        }
    }

    /// What has actually been pushed since the room opened.
    public struct Statistics: Equatable, Sendable {
        public var videoTags = 0
        public var audioTags = 0
        public var bytesSent = 0
        public var lastActivity: Date?
        /// Stream duration in seconds since start.
        public var durationSeconds: Int = 0
        /// Current bitrate in kbps.
        public var bitrateKbps: Double = 0
        /// Current FPS estimate.
        public var fps: Double = 0

        public init(
            videoTags: Int = 0,
            audioTags: Int = 0,
            bytesSent: Int = 0,
            lastActivity: Date? = nil,
            durationSeconds: Int = 0,
            bitrateKbps: Double = 0,
            fps: Double = 0
        ) {
            self.videoTags = videoTags
            self.audioTags = audioTags
            self.bytesSent = bytesSent
            self.lastActivity = lastActivity
            self.durationSeconds = durationSeconds
            self.bitrateKbps = bitrateKbps
            self.fps = fps
        }
    }

    @Published public private(set) var status: GoProTikTokRelayStatus = .idle
    @Published public private(set) var statistics = Statistics()
    @Published public private(set) var lastError: String?
    @Published public private(set) var streamInfo: GoProTikTokStreamInfo?
    /// Last thing the ingest said about the publish stream.
    @Published public private(set) var serverStatus: String = ""
    /// Set when a frame could not be muxed. The stream keeps going; without
    /// this the result is a picture that never appears and no explanation.
    @Published public private(set) var warning: String?
    /// Audio level from GoPro mic, 0.0 to 1.0 for VU meter display.
    @Published public private(set) var audioLevel: Float = 0

    private let service: GoProTikTokService
    private let transport: GoProTikTokTransport
    private let preview: GoProPreviewPlayer

    private var rtmp: GoProRtmpClient?
    private var pushTask: Task<Void, Never>?
    private var observerID: UUID?
    private var continuation: AsyncStream<GoProDemuxEvent>.Continuation?
    private var muxer = GoProLiveMuxer()
    private var audioMeter = GoProAudioLevelMeter()
    private let backgroundKeeper = GoProBackgroundKeeper()

    private var currentEndpoint: GoProRtmpEndpoint?
    private var isReconnecting = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 5

    private var lastActivity: Date?
    private var lastStatisticsPublish = Date.distantPast
    private var streamStartTime: Date?
    private var lastBytesForBitrate = 0
    private var lastBitrateTime = Date.distantPast
    private var lastVideoTagsForFps = 0
    private var lastFpsTime = Date.distantPast
    private var currentBitrateKbps: Double = 0
    private var currentFps: Double = 0

    /// Events beyond three seconds of backpressure drop at the oldest point;
    /// the ingest recovers on the next keyframe, while an unbounded queue
    /// would keep growing until memory ran out.
    private static let eventBufferLimit = 240

    public init(service: GoProTikTokService, transport: GoProTikTokTransport, preview: GoProPreviewPlayer) {
        self.service = service
        self.transport = transport
        self.preview = preview
    }

    // MARK: - Lifecycle

    /// Open the room, connect to the ingest, and start pushing.
    public func start(options: Options = Options()) async throws {
        guard status == .idle || status == .error else { return }
        status = .starting
        lastError = nil
        warning = nil
        serverStatus = ""
        muxer.reset()
        lastActivity = nil
        publishStatistics(force: true)

        do {
            let info = try await service.createStream(
                title: options.title,
                hashtagId: options.hashtagId,
                gameTagId: options.gameTagId,
                enableReplay: options.enableReplay,
                closeRoomWhenStreamEnds: true,
                regionPriority: options.regionPriority,
                isMatureContent: options.mature
            )
            streamInfo = info

            guard let endpoint = GoProRtmpEndpoint(url: info.fullRtmpUrl) else {
                throw GoProTikTokError.invalidURL(info.fullRtmpUrl)
            }

            // The frames come from the preview's socket, so nothing can
            // subscribe to the stream before the preview owns it.
            if preview.state != .streaming, preview.state != .waitingForCamera {
                try await preview.start()
            }

            let connection = try await transport.openStream(
                host: endpoint.host,
                port: endpoint.port,
                tls: endpoint.usesTLS
            )
            let client = GoProRtmpClient(connection: connection)
            client.onStatus = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.serverStatus = event.code
                }
            }
            try await client.publish(to: endpoint)
            client.startDraining()
            rtmp = client

            let (stream, queue) = AsyncStream.makeStream(
                of: GoProDemuxEvent.self,
                bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)
            )
            continuation = queue
            observerID = preview.addDemuxObserver { event in
                queue.yield(event)
            }
            pushTask = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    await self.push(event)
                }
            }

            status = .streaming
            streamStartTime = Date()
            currentEndpoint = endpoint
            isReconnecting = false
            reconnectAttempts = 0
            backgroundKeeper.start()
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
        } catch {
            lastError = error.localizedDescription
            status = .error
            await teardown(endingRoom: true)
            throw error
        }
    }

    /// Close the push and finish the room.
    public func stop() async {
        guard status != .idle else { return }
        status = .stopping
        await teardown(endingRoom: true)
        status = .idle
        serverStatus = ""
        publishStatistics(force: true)
    }

    /// Undo everything `start` set up. The room is left alone when there never
    /// was one, and the connection is dropped before the API call so the
    /// ingest sees the stream end rather than just stop receiving.
    private func teardown(endingRoom: Bool) async {
        if let observerID {
            preview.removeDemuxObserver(observerID)
            self.observerID = nil
        }
        continuation?.finish()
        continuation = nil
        pushTask?.cancel()
        pushTask = nil

        if let rtmp {
            await rtmp.close()
            self.rtmp = nil
        }
        muxer.reset()
        audioMeter.reset()
        backgroundKeeper.stop()
        audioLevel = 0
        currentEndpoint = nil
        isReconnecting = false
        reconnectAttempts = 0

        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif

        if endingRoom, let room = streamInfo, !room.roomId.isEmpty {
            _ = await service.endStream(roomId: room.roomId)
        }
    }

    // MARK: - Pushing

    /// One demux event in, in-order writes out. Nothing here blocks: the write
    /// suspends and the main actor carries on.
    private func push(_ event: GoProDemuxEvent) async {
        if case .audioFrame(let frame) = event {
            audioLevel = audioMeter.process(aacData: frame.aacData)
        }

        guard !isReconnecting, let rtmp else { return }

        for output in muxer.mux(event) {
            do {
                try await send(output, rtmp: rtmp)
            } catch {
                await handleSendError(error, rtmp: rtmp)
                return
            }
        }

        if muxer.lastWarning != warning {
            warning = muxer.lastWarning
        }
        publishStatistics()
    }

    private func handleSendError(_ error: Error, rtmp: GoProRtmpClient) async {
        guard (status == .streaming || status == .reconnecting), !isReconnecting else {
            await fail(error, rtmp: rtmp)
            return
        }

        if reconnectAttempts < Self.maxReconnectAttempts {
            await attemptReconnect(reason: error.localizedDescription, failedRtmp: rtmp)
        } else {
            await fail(error, rtmp: rtmp)
        }
    }

    private func attemptReconnect(reason: String, failedRtmp: GoProRtmpClient) async {
        guard let endpoint = currentEndpoint, (status == .streaming || status == .reconnecting) else {
            await fail(GoProRtmpError.command(reason), rtmp: failedRtmp)
            return
        }

        isReconnecting = true
        reconnectAttempts += 1
        status = .reconnecting
        warning = "Connection dropped (\(reason)). Reconnecting to TikTok LIVE (\(reconnectAttempts)/\(Self.maxReconnectAttempts))..."

        await failedRtmp.close()
        if self.rtmp === failedRtmp { self.rtmp = nil }

        let delaySeconds = UInt64(min(reconnectAttempts, 3))
        try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)

        guard status == .reconnecting || status == .streaming else {
            isReconnecting = false
            return
        }

        do {
            let connection = try await transport.openStream(
                host: endpoint.host,
                port: endpoint.port,
                tls: endpoint.usesTLS
            )
            let client = GoProRtmpClient(connection: connection)
            client.onStatus = { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.serverStatus = event.code
                }
            }
            try await client.publish(to: endpoint)
            client.startDraining()
            self.rtmp = client

            // Re-emit parameter sets (SPS/PPS) and metadata on next keyframe
            self.muxer.markHeadersNeeded()

            self.isReconnecting = false
            self.reconnectAttempts = 0
            self.status = .streaming
            self.warning = nil
        } catch {
            isReconnecting = false
            if reconnectAttempts < Self.maxReconnectAttempts, (status == .reconnecting || status == .streaming) {
                await attemptReconnect(reason: error.localizedDescription, failedRtmp: failedRtmp)
            } else {
                await fail(error, rtmp: failedRtmp)
            }
        }
    }

    private func send(_ output: GoProLiveMuxer.Output, rtmp: GoProRtmpClient) async throws {
        switch output {
        case .metadata:
            try await rtmp.sendMetadata(
                width: nil,
                height: nil,
                frameRate: nil,
                videoBitrate: nil,
                audioSampleRate: muxer.audioSampleRate,
                channels: muxer.audioChannels
            )
        case .videoSequenceHeader(let tag, let timestamp),
             .video(let tag, let timestamp):
            try await rtmp.sendVideo(tag, timestampMS: timestamp)
        case .audioSequenceHeader(let tag, let timestamp):
            try await rtmp.sendAudio(tag, timestampMS: timestamp)
        case .audio(let tag, let timestamp):
            try await rtmp.sendAudio(tag, timestampMS: timestamp)
        }
    }

    /// The push itself failed. The room closes on its own because the create
    /// call asked for it, so only the connection and the subscription go here.
    private func fail(_ error: Error, rtmp: GoProRtmpClient) async {
        lastError = error.localizedDescription
        status = .error
        isReconnecting = false
        reconnectAttempts = 0
        currentEndpoint = nil

        if let observerID {
            preview.removeDemuxObserver(observerID)
            self.observerID = nil
        }
        continuation?.finish()
        continuation = nil
        await rtmp.close()
        if self.rtmp === rtmp { self.rtmp = nil }
        publishStatistics(force: true)
    }

    /// Statistics are published about once a second: at 60 frames per second a
    /// write every frame would repaint the screen for nobody watching it.
    private func publishStatistics(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastStatisticsPublish) >= 1 else { return }
        lastStatisticsPublish = now
        lastActivity = muxer.videoTags + muxer.audioTags > 0 ? now : lastActivity

        // Duration since stream start
        let duration: Int
        if let start = streamStartTime {
            duration = Int(now.timeIntervalSince(start))
        } else {
            duration = 0
        }

        // Bitrate: bytes sent per second * 8 / 1000 = kbps
        let bitrateInterval = now.timeIntervalSince(lastBitrateTime)
        if bitrateInterval >= 1 {
            let bytesDelta = muxer.bytesSent - lastBytesForBitrate
            currentBitrateKbps = Double(bytesDelta) * 8.0 / 1000.0 / bitrateInterval
            lastBytesForBitrate = muxer.bytesSent
            lastBitrateTime = now
        }

        // FPS: video tags per second
        let fpsInterval = now.timeIntervalSince(lastFpsTime)
        if fpsInterval >= 1 {
            let tagsDelta = muxer.videoTags - lastVideoTagsForFps
            currentFps = Double(tagsDelta) / fpsInterval
            lastVideoTagsForFps = muxer.videoTags
            lastFpsTime = now
        }

        statistics = Statistics(
            videoTags: muxer.videoTags,
            audioTags: muxer.audioTags,
            bytesSent: muxer.bytesSent,
            lastActivity: lastActivity,
            durationSeconds: duration,
            bitrateKbps: currentBitrateKbps,
            fps: currentFps
        )
    }
}
