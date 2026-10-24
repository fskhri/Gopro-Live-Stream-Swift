import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Receives the camera's UDP preview datagrams.
///
/// Port of the socket half of `GoProUdpDataSource`. On Android the socket was
/// bound to the camera's `Network` object so the request never leaked onto
/// cellular; iOS has no per-network socket binding, and it does not need one,
/// because `NEHotspotConfiguration` makes the camera hotspot the default route
/// while it is joined. The socket therefore binds `INADDR_ANY` on the preview
/// port and accepts whatever arrives.
///
/// A read source is used instead of a blocking `recv` loop so that `stop()` is
/// safe from any thread and the descriptor is closed exactly once, on the
/// internal queue.
public final class GoProUdpReceiver: @unchecked Sendable {
    public enum ReceiverError: Error, LocalizedError {
        case socketUnavailable(Int32)
        case bindFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .socketUnavailable(let code):
                return "Could not create the preview socket (errno \(code))."
            case .bindFailed(let code):
                return "Could not listen on the preview port (errno \(code))."
            }
        }
    }

    public struct Statistics: Equatable, Sendable {
        public var datagrams: Int = 0
        public var bytes: Int = 0
    }

    private let queue = DispatchQueue(label: "com.gopro.rebuild.preview.udp", qos: .userInitiated)
    private let port: UInt16
    private let lock = NSLock()

    private var readSource: DispatchSourceRead?
    private var continuation: AsyncStream<Data>.Continuation?
    private var isRunning = false
    private var statisticsStore = Statistics()

    public init(port: UInt16 = GoProPreviewConfiguration.streamPort) {
        self.port = port
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statisticsStore
    }

    /// Open the socket and start delivering datagrams.
    ///
    /// - Throws: `ReceiverError` when the socket cannot be created or bound.
    /// - Returns: a stream that finishes when `stop()` is called or the socket
    ///   fails. It buffers the newest datagrams only: a live preview must not
    ///   fall behind playing stale video.
    public func start() throws -> AsyncStream<Data> {
        stop()

        let handle = try makeSocket()

        return AsyncStream<Data>(bufferingPolicy: .bufferingNewest(24)) { continuation in
            let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
            source.setEventHandler { [weak self] in
                self?.drain(handle: handle, continuation: continuation)
            }
            // The cancel handler runs on the queue after any in-flight handler,
            // so the descriptor is never closed while it is being read.
            source.setCancelHandler {
                close(handle)
            }

            lock.lock()
            readSource = source
            self.continuation = continuation
            isRunning = true
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }

            source.resume()
        }
    }

    public func stop() {
        lock.lock()
        let source = readSource
        let stream = continuation
        readSource = nil
        continuation = nil
        isRunning = false
        lock.unlock()

        stream?.finish()
        source?.cancel()
    }

    // MARK: - Socket

    private func makeSocket() throws -> Int32 {
        let handle = socket(AF_INET, SOCK_DGRAM, 0)
        guard handle >= 0 else { throw ReceiverError.socketUnavailable(errno) }

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(handle, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking, so the drain loop can return as soon as the queue is
        // empty rather than parking a queue thread inside recv.
        let currentFlags = fcntl(handle, F_GETFL, 0)
        _ = fcntl(handle, F_SETFL, currentFlags | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: 0)  // INADDR_ANY

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(handle, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(handle)
            throw ReceiverError.bindFailed(code)
        }
        return handle
    }

    /// Read every datagram waiting on the socket, then return.
    private func drain(handle: Int32, continuation: AsyncStream<Data>.Continuation) {
        var buffer = [UInt8](repeating: 0, count: GoProPreviewConfiguration.maxDatagramSize)

        while true {
            lock.lock()
            let running = isRunning
            lock.unlock()
            guard running else { return }

            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(handle, base, raw.count, 0)
            }

            guard received > 0 else {
                if received < 0 {
                    let code = errno
                    // Drained, or interrupted: wait for the next readability
                    // signal instead of spinning.
                    if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return }
                }
                // A zero-length datagram carries nothing, and any other error
                // means the socket is unusable: report and stop.
                if received == 0 { continue }
                stop()
                return
            }

            lock.lock()
            statisticsStore.datagrams += 1
            statisticsStore.bytes += received
            lock.unlock()

            continuation.yield(Data(buffer[0..<received]))
        }
    }

    deinit {
        stop()
    }
}
