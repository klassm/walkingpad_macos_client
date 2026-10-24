import Foundation

// Loopback-only WebSocket server (design: websocket.html §5).
//
// Implemented directly on BSD sockets (Network.framework's NWListener cannot be
// exercised inside the constrained test environment; BSD sockets are the
// lowest common denominator and guarantee hard loopback-only binding).
// RFC 6455 handshake/framing lives in WsFraming.swift and is fully covered by tests.
//
// Events: `connection` immediately on connect and on every state change
// (`broadcastConnection` self-dedups), plus `treadmill`/`workout` pushed by the
// app (`broadcastWorkout` self-throttles like MqttService.publish()).
// Commands are parsed with WsDispatcher; actions run through the executor and
// are answered with `ack`/`error`.

/// Executes a parsed WS command on the treadmill and reports the outcome.
/// The transport (WebSocketApi) turns outcomes into ack/error/events.
public enum WsExecutionOutcome: Equatable {
    case complete
    case reply(WsEvent)
    case failure(code: String)
}

public protocol WsCommandExecuting {
    func execute(_ action: WsAction, completion: @escaping (WsExecutionOutcome) -> Void)
}

public final class WebSocketApi {
    /// The production port; tests pass 0 (ephemeral) or an explicit port.
    public static let defaultPort: UInt16 = 4935

    /// Safety valve against thread/fd exhaustion on loopback.
    static let maximumConnections = 32

    private let lock = NSLock()
    private let executor: WsCommandExecuting
    private let connectionState: () -> String
    private let connectionTracker = WsConnectionTracker()
    private let saveTracker = WsSaveTracker()

    private var listenFD: Int32 = -1
    private var boundPortStorage: UInt16?
    private var connections: [Int32: WsSocketConnection] = [:]
    private var running = false
    private let requestedPort: UInt16 // 0 = ephemeral; the real port is read back via getsockname

    public init(executor: WsCommandExecuting, connectionState: @escaping () -> String, port: UInt16 = 0) {
        self.executor = executor
        self.connectionState = connectionState
        self.requestedPort = port
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// The port the listener actually bound (informational when port 0 was requested).
    public func boundPort() -> UInt16? {
        withLock { boundPortStorage }
    }

    // MARK: - Lifecycle

    public func start() throws {
        try withLock {
            guard listenFD == -1 else { return }

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw WsServerFailure.posix("socket", errno) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = requestedPort.bigEndian
            addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            var addrCopy = addr
            let bindResult = withUnsafePointer(to: &addrCopy) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(fd)
                throw WsServerFailure.posix("bind", errno)
            }
            guard listen(fd, 8) == 0 else {
                close(fd)
                throw WsServerFailure.posix("listen", errno)
            }

            boundPortStorage = Self.boundPort(of: fd)
            listenFD = fd
            running = true
            NSLog("WebSocketApi: listening on 127.0.0.1:%d", boundPortStorage ?? 0)
            let thread = Thread { [weak self] in self?.acceptLoop() }
            thread.qualityOfService = .background
            thread.name = "walkingpad-ws-accept"
            thread.start()
        }
    }

    public func stop() {
        let sockets: [WsSocketConnection] = withLock {
            running = false
            if listenFD != -1 {
                shutdown(listenFD, SHUT_RDWR) // wakes a blocked accept() before close
                close(listenFD)
                listenFD = -1
            }
            let sockets = Array(connections.values)
            connections.removeAll()
            return sockets
        }
        for connection in sockets {
            connection.disconnect()
        }
    }

    // MARK: - Outgoing

    public func broadcast(_ event: WsEvent) {
        guard let encoded = try? WsEventEncoding.encode(event) else { return }
        sendFrame(WsFrameEncoder.encode(.text, payload: encoded))
    }

    /// Connection state changes are deduplicated: only transitions are pushed.
    public func broadcastConnection(state: String) {
        guard connectionTracker.shouldEmit(state: state) else { return }
        broadcast(.connection(state: state))
    }

    /// Workout totals are pushed whenever a new save happened (the last save
    /// before the treadmill turns off must never be swallowed).
    public func broadcastWorkout(event: WsEvent, lastSaveTime: Date?) {
        guard let lastSaveTime, lastSaveTime != .distantPast,
              saveTracker.shouldEmitWorkout(lastSaveTime: lastSaveTime) else { return }
        broadcast(event)
    }

    /// Encodes the event once and writes the identical frame to every connection.
    private func sendFrame(_ frame: Data) {
        let sockets: [WsSocketConnection] = withLock { Array(connections.values) }
        for connection in sockets {
            connection.send(frame: frame)
        }
    }

    // MARK: - Private

    private static func boundPort(of fd: Int32) -> UInt16 {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { return 0 }
        return UInt16(bigEndian: addr.sin_port)
    }

    private func acceptLoop() {
        while true {
            let fd: Int32 = withLock {
                running ? listenFD : -1
            }
            guard fd != -1 else { return }

            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                // Transient resource pressure must not kill the accept loop.
                if [EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(errno) {
                    NSLog("WebSocketApi: accept failed with errno %d; backing off", errno)
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                return // listener closed
            }

            let connection = WsSocketConnection(fd: clientFD, executor: executor, api: self)
            // The connection registers itself only after a successful handshake
            // (broadcasts must never race the plain-HTTP upgrade phase). The
            // thread owns the connection until then.
            let thread = Thread {
                connection.serve()
            }
            thread.qualityOfService = .utility
            thread.name = "walkingpad-ws-client"
            thread.start()
        }
    }

    /// Called by a client thread once its handshake succeeded. Returns false when
    /// the connection cap is reached (caller disconnects).
    fileprivate func addConnection(_ connection: WsSocketConnection) -> Bool {
        let accepted: Bool = withLock {
            guard connections.count < Self.maximumConnections else { return false }
            connections[connection.fd] = connection
            return true
        }
        if accepted {
            // Seed the dedup tracker: the per-connection initial event (sent
            // un-gated in serve) already carries this state, so the app's next
            // unchanged callback must not re-emit it.
            _ = connectionTracker.shouldEmit(state: currentState())
            NSLog("WebSocketApi: client connected (fd %d, %d active)", connection.fd, withLock { connections.count })
        }
        return accepted
    }

    fileprivate func removeConnection(_ connection: WsSocketConnection) {
        withLock {
            if connections[connection.fd] === connection {
                connections.removeValue(forKey: connection.fd)
            }
        }
        NSLog("WebSocketApi: client disconnected (fd %d)", connection.fd)
    }

    fileprivate func currentState() -> String {
        connectionState()
    }
}

enum WsServerFailure: Error {
    case posix(String, Int32)
}

/// Outcome of the upgrade handshake on a client socket.
private enum HandshakeOutcome {
    case upgraded(leftover: Data)
    case preflight
    case failed
}

/// One accepted (and optionally upgraded) WebSocket connection on a raw file descriptor.
final class WsSocketConnection {
    let fd: Int32
    private let executor: WsCommandExecuting
    private weak var api: WebSocketApi?
    private let writeLock = NSLock()
    private let lifecycleLock = NSLock()
    private var closed = false
    private var decoder = WsFrameDecoder()

    init(fd: Int32, executor: WsCommandExecuting, api: WebSocketApi) {
        self.fd = fd
        self.executor = executor
        self.api = api
    }

    /// Blocking connection lifetime: handshake → registration → initial connection
    /// event → frame loop → cleanup.
    func serve() {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Bound the handshake phase; a TCP connect that never speaks must not
        // pin this thread forever.
        Self.setSocketTimeouts(fd: fd, seconds: 5)

        // Chrome 147+ probes the port with an OPTIONS preflight before the
        // real upgrade (Local Network Access); answer it and close cleanly.
        let outcome = performHandshake()
        let leftover: Data
        switch outcome {
        case let .upgraded(bytes):
            leftover = bytes
        case .preflight:
            disconnect()
            return
        case .failed:
            NSLog("WebSocketApi: handshake failed (fd %d)", fd)
            disconnect()
            return
        }
        // Idle WS connections must not die on the handshake timeout.
        Self.setSocketTimeouts(fd: fd, seconds: 0)

        guard let api, api.addConnection(self) else {
            if api == nil {
                NSLog("WebSocketApi: dropping connection without server (fd %d)", fd)
            } else {
                NSLog("WebSocketApi: connection cap reached, dropping (fd %d)", fd)
            }
            disconnect()
            return
        }

        var connectionClosed = false
        // Any bytes the client pipelined behind the upgrade request belong to
        // the frame stream, not the handshake.
        if !leftover.isEmpty {
            for frame in decoder.feed(leftover) {
                if !handle(frame) {
                    connectionClosed = true
                    break
                }
            }
        }

        // Design §5: push the current connection state to every new client.
        if !connectionClosed, let event = try? WsEventEncoding.encode(.connection(state: api.currentState())) {
            send(frame: WsFrameEncoder.encode(.text, payload: event))
        }

        var buffer = [UInt8](repeating: 0, count: 8192)
        while !connectionClosed {
            let received = recv(fd, &buffer, buffer.count, 0)
            if received < 0 {
                if errno == EINTR { continue }
                break
            }
            if received == 0 {
                break
            }
            let chunk = Data(buffer[0..<received])
            for frame in decoder.feed(chunk) {
                if !handle(frame) {
                    connectionClosed = true
                    break
                }
            }
        }
        disconnect()
        api.removeConnection(self)
    }

    /// Handles one decoded frame; false when the connection should end.
    private func handle(_ frame: WsIncomingFrame) -> Bool {
        // Any URL path is accepted upstream (parity with the plain HTTP API).
        switch frame.opcode {
        case .close:
            send(frame: WsFrameEncoder.encode(.close, payload: frame.payload))
            return false
        case .ping:
            send(frame: WsFrameEncoder.encode(.pong, payload: frame.payload))
            return true
        case .pong:
            return true
        case .text, .binary:
            dispatchCommand(payload: frame.payload)
            return true
        case .continuation:
            // Should have been merged by the decoder; ignore defensively.
            return true
        }
    }

    private func dispatchCommand(payload: Data) {
        switch WsDispatcher.dispatch(payload) {
        case let .action(id, action):
            executor.execute(action) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .complete:
                    self.send(event: .ack(id: id))
                case let .reply(event):
                    self.send(event: event)
                case let .failure(code):
                    self.send(event: .error(id: id, code: code))
                }
            }
        case let .failure(id, code):
            send(event: .error(id: id, code: code))
        }
    }

    func send(event: WsEvent) {
        guard let encoded = try? WsEventEncoding.encode(event) else { return }
        send(frame: WsFrameEncoder.encode(.text, payload: encoded))
    }

    func send(frame: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !Self.writeAll(fd: fd, data: frame) {
            NSLog("WebSocketApi: write failed, dropping connection (fd %d)", fd)
            disconnect()
            api?.removeConnection(self)
        }
    }

    private static func setSocketTimeouts(fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        // A stalled peer must not block a broadcast (or this thread) forever.
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { pointer -> Int in
                pointer.baseAddress.map {
                    write(fd, $0.advanced(by: sent), data.count - sent)
                } ?? -1
            }
            if written <= 0 { return false }
            sent += written
        }
        return true
    }

    /// Performs the RFC 6455 upgrade; returns the frame bytes the client sent
    /// behind the request head. `.preflight` when an OPTIONS probe was answered
    /// (connection must be closed), `.failed` when the request is invalid.
    private func performHandshake() -> HandshakeOutcome {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var request = Data()
        while true {
            let received = recv(fd, &buffer, buffer.count, 0)
            if received < 0 {
                if errno == EINTR { continue }
                return .failed
            }
            if received == 0 { return .failed }
            request += Data(buffer[0..<received])
            if let headEnd = request.range(of: Data("\r\n\r\n".utf8)) {
                let leftover = request[headEnd.upperBound...]
                let head = request[request.startIndex..<headEnd.upperBound]
                guard let text = String(data: head, encoding: .utf8) else { return .failed }
                if text.hasPrefix("OPTIONS ") {
                    Self.writeAll(fd: fd, data: Data(WsHandshake.preflightResponse().utf8))
                    return .preflight
                }
                guard let parsed = WsHandshake.parse(text) else {
                    let requestLine = text.components(separatedBy: "\r\n").first ?? "?"
                    NSLog("WebSocketApi: rejected handshake request: %@", requestLine)
                    return .failed
                }
                let acceptKey = WsHandshake.acceptKey(forKey: parsed.key)
                let response = WsHandshake.response(acceptKey: acceptKey)
                guard Self.writeAll(fd: fd, data: Data(response.utf8)) else { return .failed }
                return .upgraded(leftover: Data(leftover))
            }
            if request.count > 64 * 1024 { return .failed }
        }
    }

    /// Idempotent: after the first close the fd is forgotten so a stale close
    /// can never hit an fd number the kernel handed to someone else.
    func disconnect() {
        lifecycleLock.lock()
        if closed {
            lifecycleLock.unlock()
            return
        }
        closed = true
        lifecycleLock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}
