import Foundation
import os

struct WorkoutApiData: Codable {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
    var date: String
}

struct TreadmillState : Codable {
    var steps: Int
    var distance: Int
    var walkingSeconds: Int
    var speed: Double
}

struct ConnectionState : Codable {
    var state: String
}

struct HttpResponse {
    let status: Int
    let reason: String
    let headers: [(String, String)]
    let body: Data

    static func json(_ status: Int, _ reason: String, _ data: Data) -> HttpResponse {
        HttpResponse(status: status, reason: reason, headers: [("content-type", "application/json"), ("access-control-allow-origin", "*")], body: data)
    }

    static func empty(_ status: Int, _ reason: String) -> HttpResponse {
        HttpResponse(status: status, reason: reason, headers: [], body: Data())
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "content-length: \(body.count)\r\nconnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

struct ParsedHttpRequest {
    let method: String
    let path: String
    let totalLength: Int
}

protocol HttpTreadmillProviding {
    func command() -> WalkingPadCommanding?
    func lastStatus() -> DeviceState?
    func isConnected() -> Bool
}

extension WalkingPadService: HttpTreadmillProviding {}

protocol HttpWorkoutProviding {
    var steps: Int { get }
    var distance: Int { get }
    var walkingSeconds: Int { get }
    func loadAll() -> [WorkoutSaveData]
}

extension Workout: HttpWorkoutProviding {}

// Small JSON API on 127.0.0.1:4934. BSD-sockets transport, the same proven
// pattern as WebSocketApi: NWListener never became ready inside the App
// Sandbox (connection refused on 4934 — observed on the host, unfixable via
// parameters), while raw POSIX sockets work reliably. Loopback-only is
// guaranteed at bind time: bind(INADDR_LOOPBACK), never INADDR_ANY.
final class HttpApi {
    private static let logger = Logger(subsystem: "klassm.walkingpad-client", category: "http")
    static let defaultPort: UInt16 = 4934

    private let treadmill: HttpTreadmillProviding
    private let workout: HttpWorkoutProviding
    private let port: UInt16
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundPortStorage: UInt16?

    init(treadmill: HttpTreadmillProviding, workout: HttpWorkoutProviding, port: UInt16 = HttpApi.defaultPort) {
        self.treadmill = treadmill
        self.workout = workout
        self.port = port
    }

    func boundPort() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundPortStorage
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD == -1 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.logger.error("HTTP socket() failed, errno \(errno)")
            return
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Self.logger.error("HTTP bind to 127.0.0.1:\(self.port) failed, errno \(errno)")
            close(fd)
            return
        }
        guard listen(fd, 16) == 0 else {
            Self.logger.error("HTTP listen failed, errno \(errno)")
            close(fd)
            return
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &boundLength)
            }
        }
        if nameResult == 0 {
            self.boundPortStorage = UInt16(bigEndian: bound.sin_port)
        }

        listenFD = fd
        Self.logger.notice("HTTP server listening on 127.0.0.1:\(self.boundPortStorage.map(String.init) ?? "?")")

        Thread { [weak self] in
            guard let self else {
                close(fd)
                return
            }
            self.acceptLoop(fd: fd)
        }.start()
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func acceptLoop(fd: Int32) {
        while true {
            var peer = sockaddr()
            var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(fd, &peer, &peerLength)
            if clientFD == -1 {
                if errno == EINTR { continue }
                if errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM {
                    usleep(100_000)
                    continue
                }
                Self.logger.error("HTTP accept failed, errno \(errno) — listener stopped")
                break
            }
            Thread {
                self.serveConnection(fd: clientFD)
            }.start()
        }
    }

    private func serveConnection(fd: Int32) {
        setSocketTimeouts(fd: fd, seconds: 5)
        defer { close(fd) }

        var buffer = Data()
        while true {
            var chunk = [UInt8](repeating: 0, count: 8192)
            let received = recv(fd, &chunk, chunk.count, 0)
            if received == -1 {
                if errno == EINTR { continue }
                Self.logger.error("HTTP receive error, errno \(errno)")
                return
            }
            guard received > 0 else { return } // EOF or recv timeout

            buffer.append(contentsOf: chunk[0..<received])
            guard let request = Self.parseRequest(from: buffer) else {
                if buffer.count > 1_000_000 {
                    Self.logger.warning("HTTP request exceeded 1 MB, closing connection")
                    return
                }
                continue
            }

            Self.logger.notice("HTTP request: \(request.method, privacy: .public) \(request.path, privacy: .public)")
            let response = self.handle(method: request.method, path: request.path)

            let data = response.serialized()
            var sent = 0
            var writeFailed = false
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                while sent < data.count {
                    let written = write(fd, base.advanced(by: sent), data.count - sent)
                    if written == -1 {
                        if errno == EINTR { continue }
                        writeFailed = true
                        break
                    }
                    sent += written
                }
            }
            if writeFailed {
                Self.logger.error("HTTP send error, dropping connection")
            } else {
                Self.logger.notice("HTTP response sent: \(response.status)")
            }
            return // connection: close per request
        }
    }

    private func setSocketTimeouts(fd: Int32, seconds: Int32) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func parseRequest(from data: Data) -> ParsedHttpRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        guard let headerText = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1)
            if pieces.count == 2, pieces[0].lowercased() == "content-length",
               let length = Int(pieces[1].trimmingCharacters(in: .whitespaces)) {
                contentLength = length
            }
        }
        let totalLength = headerEnd.upperBound + contentLength
        guard data.count >= totalLength else {
            return nil
        }
        return ParsedHttpRequest(method: String(parts[0]), path: String(parts[1]), totalLength: totalLength)
    }

    func handle(method: String, path: String) -> HttpResponse {
        switch (method, path) {
        case ("GET", "/treadmill"):
            return self.treadmillState()
        case ("GET", "/treadmill/connection"):
            return self.connectionState()
        case ("GET", "/treadmill/workouts"):
            return self.workouts()
        case ("POST", "/treadmill/start"):
            return self.withCommand { $0.start() }
        case ("POST", "/treadmill/stop"):
            return self.withCommand { $0.setSpeed(speed: 0) }
        case ("POST", "/treadmill/faster"):
            return self.withCommand { command in
                if let speed = self.treadmill.lastStatus()?.speed {
                    // Clamped like the WS executor (WebSocketApi) so the two
                    // transports cannot drive the belt beyond 8.0 km/h.
                    command.setSpeed(speed: UInt8(min(80, speed + 5)))
                } else {
                    command.start()
                }
            }
        case ("POST", "/treadmill/slower"):
            return self.withCommand { command in
                if let speed = self.treadmill.lastStatus()?.speed {
                    // Guarded like the WS executor: UInt8(speed - 5) would trap
                    // for speed < 5.
                    command.setSpeed(speed: speed > 5 ? UInt8(speed - 5) : 0)
                } else {
                    command.setSpeed(speed: 0)
                }
            }
        default:
            if method == "POST", path.hasPrefix("/treadmill/speed/") {
                let speedString = path.dropFirst("/treadmill/speed/".count)
                if let speed = UInt8(speedString), speed >= 10, speed <= 80, speed % 10 == 0 {
                    return self.withCommand { $0.setSpeed(speed: speed) }
                }
                return .empty(404, "Not found")
            }
            return .empty(404, "Not found")
        }
    }

    private func treadmillState() -> HttpResponse {
        let state = TreadmillState(
            steps: self.workout.steps,
            distance: self.workout.distance,
            walkingSeconds: self.workout.walkingSeconds,
            speed: self.treadmill.lastStatus()?.speedKmh() ?? 0
        )
        do {
            return .json(200, "OK", try JSONEncoder().encode(state))
        } catch {
            Self.logger.error("Failed to encode treadmill state: \(String(describing: error), privacy: .public)")
            return .empty(500, "Error")
        }
    }

    private func connectionState() -> HttpResponse {
        let state = TreadmillConnectionState(
            isConnected: self.treadmill.isConnected(),
            speed: self.treadmill.lastStatus()?.speed ?? 0
        )
        do {
            return .json(200, "OK", try JSONEncoder().encode(ConnectionState(state: state.rawValue)))
        } catch {
            Self.logger.error("Failed to encode connection state: \(String(describing: error), privacy: .public)")
            return .empty(500, "Error")
        }
    }

    private func workouts() -> HttpResponse {
        // Created per call: the response runs on per-connection threads and
        // DateFormatter is not thread-safe.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let workouts = self.workout.loadAll().map { entry in
            WorkoutApiData(
                steps: entry.steps,
                distance: entry.distance,
                walkingSeconds: entry.walkingSeconds,
                date: formatter.string(from: entry.date)
            )
        }
        do {
            return .json(200, "OK", try JSONEncoder().encode(workouts))
        } catch {
            Self.logger.error("Failed to encode workouts: \(String(describing: error), privacy: .public)")
            return .empty(500, "Error")
        }
    }

    private func withCommand(_ action: (WalkingPadCommanding) -> Void) -> HttpResponse {
        guard let command = self.treadmill.command() else {
            return .empty(428, "Treadmill not connected")
        }
        action(command)
        return .empty(200, "OK")
    }
}

@discardableResult
func startHttpServer(walkingPadService: WalkingPadService, workout: Workout) -> HttpApi? {
    let server = HttpApi(treadmill: walkingPadService, workout: workout)
    server.start()
    guard server.boundPort() != nil else {
        Logger(subsystem: "klassm.walkingpad-client", category: "http").error("Failed to start HTTP server on 127.0.0.1:\(HttpApi.defaultPort)")
        return nil
    }
    return server
}
