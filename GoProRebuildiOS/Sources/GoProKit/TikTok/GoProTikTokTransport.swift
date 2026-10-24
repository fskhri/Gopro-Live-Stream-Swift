import Foundation
import Network

/// Outbound interfaces tried, in order, when opening a connection.
///
/// While the preview runs the phone is joined to the camera's hotspot, which
/// has no internet route. TikTok's HTTP API and the RTMP host are only
/// reachable over cellular, so every connection leaving the camera's network
/// asks for `.cellular` first and falls back to whatever the system has. The
/// fallback is what keeps a simulator or a WiFi-only phone working.
public enum GoProTikTokInterface: Sendable, CaseIterable {
    case cellular
    case any
}

/// One HTTP/1.1 request, as raw bytes.
public struct GoProHTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Request line, headers, blank line, body.
    ///
    /// `Connection: close` is always asked for, so a response that carries
    /// neither `Content-Length` nor chunked framing can still be delimited:
    /// the peer closing ends the body.
    public var wireData: Data {
        guard let host = url.host else { return Data() }
        let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = comp?.percentEncodedPath ?? (url.path.isEmpty ? "/" : url.path)
        let normalizedPath = path.isEmpty ? "/" : path
        let query = comp?.percentEncodedQuery ?? url.query
        let target = normalizedPath + (query.map { "?\($0)" } ?? "")

        let fallbackPort = url.scheme == "https" ? 443 : 80
        let port = url.port ?? fallbackPort
        let hostHeader = port == fallbackPort ? host : "\(host):\(port)"

        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(hostHeader)"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        if let body {
            lines.append("Content-Length: \(body.count)")
        }
        lines.append("Connection: close")
        lines.append("")

        var data = Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        data.append(body ?? Data())
        return data
    }
}

/// A parsed HTTP/1.1 response. Header keys are lowercased.
public struct GoProHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var bodyText: String { String(data: body, encoding: .utf8) ?? "" }
}

/// A byte stream over one TCP connection.
///
/// Reads hand back whatever arrived, so a caller that needs fixed-size framing
/// (the RTMP chunk reader) keeps its own buffer.
public final class GoProByteStream: @unchecked Sendable {
    public enum StreamError: Error, LocalizedError, Equatable {
        case closed
        case timedOut
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .closed: return "Connection closed."
            case .timedOut: return "Connection timed out."
            case .failed(let detail): return "Connection failed: \(detail)"
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "gopro.tiktok.byteStream")
    private var pending = Data()
    private var endError: Error?
    /// A reader parked on `read()`, woken with bytes or with the stream error.
    private var readWaiter: ((Result<Data, Error>) -> Void)?
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var readyTimeoutWork: DispatchWorkItem?
    private var isReady = false
    private var started = false
    private var stopped = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Begin connecting. Readiness is observed through `waitUntilReady`.
    public func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async { self.handle(state: state) }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            #if DEBUG
            if let path = connection.currentPath {
                let cell = path.usesInterfaceType(.cellular)
                let wifi = path.usesInterfaceType(.wifi)
                print("[Transport] Ready: cellular=\(cell), wifi=\(wifi)")
            }
            #endif
            markReady(true)
        case .failed(let error):
            #if DEBUG
            print("[Transport] Failed: \(error)")
            #endif
            markReady(false)
            finish(with: StreamError.failed(error.localizedDescription))
        case .cancelled:
            markReady(false)
            finish(with: StreamError.closed)
        case .waiting(let error):
            #if DEBUG
            print("[Transport] Waiting for path: \(error)")
            #endif
            // Leave readiness pending so caller's timeout timer or radio wake-up can complete.
            break
        default:
            break
        }
    }

    /// Wait for the connection to become usable.
    public func waitUntilReady(timeout: TimeInterval) async -> Bool {
        if isReady { return true }
        return await withCheckedContinuation { continuation in
            queue.async {
                if self.isReady {
                    continuation.resume(returning: true)
                    return
                }
                if self.endError != nil {
                    continuation.resume(returning: false)
                    return
                }
                self.readyWaiters.append(continuation)
                let work = DispatchWorkItem { [weak self] in
                    self?.markReady(false)
                }
                self.readyTimeoutWork = work
                self.queue.asyncAfter(deadline: .now() + timeout, execute: work)
            }
        }
    }

    private func markReady(_ ready: Bool) {
        readyTimeoutWork?.cancel()
        readyTimeoutWork = nil
        guard !readyWaiters.isEmpty || ready else { return }
        if ready { isReady = true }
        let waiters = readyWaiters
        readyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: isReady)
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: StreamError.failed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Next chunk of received bytes. Throws once the connection ends.
    public func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if !self.pending.isEmpty {
                    let data = self.pending
                    self.pending.removeAll(keepingCapacity: true)
                    continuation.resume(returning: data)
                    return
                }
                if let endError = self.endError {
                    continuation.resume(throwing: endError)
                    return
                }
                var didResume = false
                self.readWaiter = { result in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Next chunk of received bytes, or `nil` when nothing arrives in time.
    ///
    /// Unlike `armDeadline`, a timeout here leaves the connection open: the
    /// bytes that were waiting are still waiting, so the caller can come back.
    /// Used where a reply is expected but silence is not fatal, as when a
    /// publishing session waits for `onStatus`.
    public func read(waitingUpTo interval: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            queue.async {
                if !self.pending.isEmpty {
                    let data = self.pending
                    self.pending.removeAll(keepingCapacity: true)
                    continuation.resume(returning: data)
                    return
                }
                if let endError = self.endError {
                    continuation.resume(throwing: endError)
                    return
                }

                var didResume = false
                var timeoutWork: DispatchWorkItem?

                timeoutWork = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    guard !didResume else { return }
                    didResume = true
                    self.readWaiter = nil
                    continuation.resume(returning: nil)
                }

                self.readWaiter = { result in
                    guard !didResume else { return }
                    didResume = true
                    timeoutWork?.cancel()
                    continuation.resume(with: result.map { Optional($0) })
                }

                if let timeoutWork {
                    self.queue.asyncAfter(deadline: .now() + interval, execute: timeoutWork)
                }
            }
        }
    }

    private var deadlineWork: DispatchWorkItem?

    /// Fail the stream if it has not finished within `interval`.
    ///
    /// This is a whole-transfer deadline, not an idle timer: it is armed once
    /// per request. Arming again replaces any deadline still pending, so a
    /// caller can keep one armed across a sequence of reads.
    public func armDeadline(after interval: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.deadlineWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.endError == nil, !self.stopped else { return }
                self.finish(with: StreamError.timedOut)
                self.connection.cancel()
            }
            self.deadlineWork = work
            self.queue.asyncAfter(deadline: .now() + interval, execute: work)
        }
    }

    /// Drop a pending deadline.
    ///
    /// Used when a phase that needed a timeout finishes and the connection now
    /// has to stay open indefinitely, as an RTMP publish does.
    public func cancelDeadline() {
        queue.async { [weak self] in
            self?.deadlineWork?.cancel()
            self?.deadlineWork = nil
        }
    }

    public func close() {
        queue.async {
            self.finish(with: StreamError.closed)
            guard !self.stopped else { return }
            self.stopped = true
            self.connection.cancel()
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.pending.append(data)
                    // Hand the bytes over immediately: a reader is parked on
                    // `read()` until someone wakes it.
                    if let waiter = self.readWaiter {
                        self.readWaiter = nil
                        let delivered = self.pending
                        self.pending.removeAll(keepingCapacity: true)
                        waiter(.success(delivered))
                    }
                }
                if let error {
                    self.finish(with: StreamError.failed(error.localizedDescription))
                    return
                }
                if isComplete {
                    self.finish(with: StreamError.closed)
                    return
                }
                if self.endError == nil && !self.stopped {
                    self.receiveNext()
                }
            }
        }
    }

    private func finish(with error: Error) {
        guard endError == nil else { return }
        endError = error
        markReady(false)
        if let waiter = readWaiter {
            readWaiter = nil
            if pending.isEmpty {
                waiter(.failure(error))
            } else {
                let data = pending
                pending.removeAll(keepingCapacity: true)
                waiter(.success(data))
            }
        }
    }
}

/// One HTTP round trip, injected so tests do not need a network.
public protocol GoProTikTokHTTPClient: AnyObject {
    func send(_ request: GoProHTTPRequest) async throws -> GoProHTTPResponse
}

/// HTTP and raw-stream transport pinned to the cellular interface.
///
/// Replaces the parts of `TiktokService.kt` that used `OkHttpClient`. Android
/// could send TikTok traffic over the default route because the camera ran on a
/// separate local-only network; here that separation has to be requested with
/// `NWParameters.requiredInterfaceType`.
public final class GoProTikTokTransport: GoProTikTokHTTPClient, @unchecked Sendable {
    /// Interfaces tried in order when opening a connection.
    public var interfaces: [GoProTikTokInterface]

    /// Whole-request deadline, matching Android's 15 s connect / 20 s read.
    public var requestTimeout: TimeInterval

    /// How long one interface may take to become ready before the next is tried.
    public var connectTimeout: TimeInterval

    public init(
        interfaces: [GoProTikTokInterface] = [.cellular, .any],
        requestTimeout: TimeInterval = 20,
        connectTimeout: TimeInterval = 10
    ) {
        self.interfaces = interfaces
        self.requestTimeout = requestTimeout
        self.connectTimeout = connectTimeout
    }

    public enum TransportError: Error, LocalizedError, Equatable {
        case unsupportedURL(String)
        case malformedResponse(String)
        case noInterface(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedURL(let url): return "Unsupported URL: \(url)"
            case .malformedResponse(let detail): return "Malformed HTTP response: \(detail)"
            case .noInterface(let detail): return "No usable network interface: \(detail)"
            }
        }
    }

    /// Send one request and read the response to completion.
    public func send(_ request: GoProHTTPRequest) async throws -> GoProHTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = request.url.host else {
            throw TransportError.unsupportedURL(request.url.absoluteString)
        }
        let port = UInt16(request.url.port ?? (scheme == "https" ? 443 : 80))

        let stream = try await openStream(host: host, port: port, tls: scheme == "https")
        defer { stream.close() }

        try await stream.write(request.wireData)
        stream.armDeadline(after: requestTimeout)

        var buffer = Data()
        while true {
            if let parsed = Self.response(buffer, ended: false) {
                switch parsed {
                case .complete(let response): return response
                case .needMore: break
                }
            }
            do {
                buffer.append(try await stream.read())
            } catch {
                // The peer closed or the deadline fired: a response framed only
                // by the close is complete now.
                if let final = Self.response(buffer, ended: true), case .complete(let response) = final {
                    return response
                }
                throw error
            }
        }
    }

    /// Open a raw connection, trying each interface in turn.
    public func openStream(host: String, port: UInt16, tls: Bool) async throws -> GoProByteStream {
        var lastFailure = "no interface attempted"
        for mode in interfaces {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 2
            tcpOptions.keepaliveInterval = 2
            tcpOptions.keepaliveCount = 3
            tcpOptions.noDelay = true

            let parameters: NWParameters
            if tls {
                parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
            } else {
                parameters = NWParameters(tls: nil, tcp: tcpOptions)
            }
            parameters.serviceClass = .interactiveVideo
            parameters.prohibitExpensivePaths = false
            parameters.prohibitConstrainedPaths = false
            if mode == .cellular {
                parameters.requiredInterfaceType = .cellular
            }

            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                lastFailure = "invalid port \(port)"
                continue
            }
            #if DEBUG
            print("[Transport] Attempting interface \(mode) to \(host):\(port)...")
            #endif
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
            let stream = GoProByteStream(connection: connection)
            stream.start()

            if await stream.waitUntilReady(timeout: connectTimeout) {
                #if DEBUG
                print("[Transport] Successfully connected via \(mode)!")
                #endif
                return stream
            }
            stream.close()
            #if DEBUG
            print("[Transport] Interface \(mode) did not become ready within \(connectTimeout)s")
            #endif
            lastFailure = "interface \(mode) did not become ready"
        }
        throw TransportError.noInterface(lastFailure)
    }
}

// MARK: - Response framing

extension GoProTikTokTransport {
    enum ParsedResponse {
        case complete(GoProHTTPResponse)
        case needMore
    }

    /// Decide whether `data` holds a whole response yet.
    ///
    /// Returns `nil` when the bytes cannot be an HTTP response at all. A
    /// response with neither `Content-Length` nor chunked framing only
    /// completes when `ended` is true.
    static func response(_ data: Data, ended: Bool) -> ParsedResponse? {
        guard let headerEnd = find(data, Data("\r\n\r\n".utf8)) else {
            return ended || data.count > 32_768 ? nil : .needMore
        }
        let head = Data(data[..<headerEnd])
        guard let headText = String(data: head, encoding: .isoLatin1) else { return nil }

        var lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/") else { return nil }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let body = Data(data[(headerEnd + 4)...])

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = decodeChunked(body) else {
                return ended ? nil : .needMore
            }
            return .complete(GoProHTTPResponse(status: status, headers: headers, body: decoded))
        }
        if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard body.count >= length else { return ended ? nil : .needMore }
            return .complete(GoProHTTPResponse(status: status, headers: headers, body: Data(body.prefix(length))))
        }
        guard ended else { return .needMore }
        return .complete(GoProHTTPResponse(status: status, headers: headers, body: body))
    }

    /// Read one chunked body, or `nil` while it is still incomplete.
    static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var offset = data.startIndex

        while true {
            guard let lineEnd = find(data, Data("\r\n".utf8), from: offset) else { return nil }
            let sizeLine = String(decoding: data[offset..<lineEnd], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }

            if size == 0 { return result }

            let dataStart = lineEnd + 2
            let dataEnd = dataStart + size
            guard dataEnd <= data.endIndex else { return nil }
            result.append(Data(data[dataStart..<dataEnd]))

            offset = dataEnd
            guard find(data, Data("\r\n".utf8), from: offset) != nil else { return nil }
            offset += 2
        }
    }

    /// First index of `needle` at or after `start`.
    static func find(_ haystack: Data, _ needle: Data, from start: Data.Index? = nil) -> Data.Index? {
        guard !needle.isEmpty else { return nil }
        let startIndex = start ?? haystack.startIndex
        guard startIndex <= haystack.endIndex else { return nil }
        // A Data slice can carry a non-zero start index; search on plain bytes.
        let haystackBytes = [UInt8](haystack[startIndex...])
        let needleBytes = [UInt8](needle)
        guard haystackBytes.count >= needleBytes.count else { return nil }

        var index = 0
        while index + needleBytes.count <= haystackBytes.count {
            if Array(haystackBytes[index..<index + needleBytes.count]) == needleBytes {
                return startIndex + index
            }
            index += 1
        }
        return nil
    }
}
