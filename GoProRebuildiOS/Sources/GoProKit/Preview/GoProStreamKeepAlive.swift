import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Sends the heartbeat that keeps the camera pushing preview packets.
///
/// Port of `PreviewPlayer.keepPreviewAlive()`. The camera stops streaming after
/// a short idle period, so the client has to write the `_GPHD_` payload on the
/// preview port even though the socket carries no other traffic.
///
/// The socket is opened lazily and reopened after any send failure, so the
/// timer can keep running while the hotspot is still being joined.
public final class GoProStreamKeepAlive: @unchecked Sendable {
    public struct Statistics: Equatable, Sendable {
        public var heartbeats: Int = 0
        public var reconnects: Int = 0
    }

    private let queue = DispatchQueue(label: "com.gopro.rebuild.preview.keepalive", qos: .userInitiated)
    private let host: String
    private let port: UInt16
    private let interval: TimeInterval
    private let payload = GoProPreviewConfiguration.keepAlivePayload

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var handle: Int32 = -1
    private var statisticsStore = Statistics()

    public init(
        host: String = GoProPreviewConfiguration.cameraHost,
        port: UInt16 = GoProPreviewConfiguration.streamPort,
        interval: TimeInterval = GoProPreviewConfiguration.keepAliveInterval
    ) {
        self.host = host
        self.port = port
        self.interval = interval
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statisticsStore
    }

    public func start() {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeat()
        }

        lock.lock()
        self.timer = timer
        lock.unlock()

        timer.resume()
    }

    public func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.cancel()

        // The timer handler owns the socket, so close it on the timer queue.
        queue.async { [weak self] in
            self?.closeSocket()
        }
    }

    // MARK: - Sending

    private func sendHeartbeat() {
        if currentHandle() < 0 {
            guard let opened = makeConnectedSocket() else { return }
            lock.lock()
            handle = opened
            statisticsStore.reconnects += 1
            lock.unlock()
        }

        let socketHandle = currentHandle()
        guard socketHandle >= 0 else { return }

        let sent = payload.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return send(socketHandle, base, raw.count, 0)
        }

        if sent < 0 {
            // The link went away; reopen on the next tick.
            closeSocket()
            return
        }

        lock.lock()
        statisticsStore.heartbeats += 1
        lock.unlock()
    }

    private func currentHandle() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    /// Connect once to the fixed camera address so every heartbeat is a plain
    /// `send`, and a missing route fails immediately instead of timing out.
    private func makeConnectedSocket() -> Int32? {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            close(handle)
            return nil
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(handle, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(handle)
            return nil
        }
        return handle
    }

    private func closeSocket() {
        lock.lock()
        let socketHandle = handle
        handle = -1
        lock.unlock()

        if socketHandle >= 0 {
            close(socketHandle)
        }
    }

    deinit {
        // The timer handler holds only a weak reference to this object, so no
        // handler can be running now: the descriptor is safe to close directly.
        timer?.cancel()
        if handle >= 0 {
            close(handle)
        }
    }
}
