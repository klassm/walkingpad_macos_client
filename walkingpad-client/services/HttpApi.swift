import Foundation
import Network
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

private struct ParsedHttpRequest {
    let method: String
    let path: String
    let totalLength: Int
}

// Small JSON API on port 4934, backed by Network.framework (replaces Embassy).
final class HttpApi {
    private static let logger = Logger(subsystem: "klassm.walkingpad-client", category: "http")
    private static let port: NWEndpoint.Port = 4934
    
    private let walkingPadService: WalkingPadService
    private let workout: Workout
    private let listener: NWListener
    private let dateFormatter: DateFormatter
    
    init(walkingPadService: WalkingPadService, workout: Workout) throws {
        self.walkingPadService = walkingPadService
        self.workout = workout
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateFormat = "yyyy-MM-dd"
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: Self.port)
    }
    
    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.logger.notice("HTTP connection ready")
                case .waiting(let error):
                    Self.logger.warning("HTTP connection waiting: \(String(describing: error), privacy: .public)")
                case .failed(let error):
                    Self.logger.error("HTTP connection failed: \(String(describing: error), privacy: .public)")
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "walkingpad.http.connection", target: .global()))
            self.receive(on: connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Self.logger.notice("HTTP server ready on port \(Self.port.rawValue)")
            case .waiting(let error):
                Self.logger.warning("HTTP server waiting: \(String(describing: error), privacy: .public)")
            case .failed(let error):
                Self.logger.error("HTTP server failed: \(String(describing: error), privacy: .public)")
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "walkingpad.http.listener", target: .global()))
    }
    
    func stop() {
        listener.cancel()
    }
    
    private func receive(on connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error {
                Self.logger.error("HTTP receive error: \(String(describing: error), privacy: .public)")
            }
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            guard let request = Self.parseRequest(from: buffer) else {
                if isComplete || buffer.count > 1_000_000 {
                    Self.logger.warning("HTTP incomplete request, closing connection")
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
                return
            }
            Self.logger.notice("HTTP request: \(request.method, privacy: .public) \(request.path, privacy: .public)")
            let response = self.handle(method: request.method, path: request.path)
            connection.send(content: response.serialized(), completion: .contentProcessed { sendError in
                if let sendError {
                    Self.logger.error("HTTP send error: \(String(describing: sendError), privacy: .public)")
                } else {
                    Self.logger.notice("HTTP response sent: \(response.status)")
                }
                connection.cancel()
            })
        }
    }

    private static func parseRequest(from data: Data) -> ParsedHttpRequest? {
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
    
    private func handle(method: String, path: String) -> HttpResponse {
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
                if let speed = self.walkingPadService.lastStatus()?.speed {
                    command.setSpeed(speed: UInt8(speed + 5))
                } else {
                    command.start()
                }
            }
        case ("POST", "/treadmill/slower"):
            return self.withCommand { command in
                if let speed = self.walkingPadService.lastStatus()?.speed {
                    command.setSpeed(speed: UInt8(speed - 5))
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
            speed: self.walkingPadService.lastStatus()?.speedKmh() ?? 0
        )
        do {
            return .json(200, "OK", try JSONEncoder().encode(state))
        } catch {
            Self.logger.error("Failed to encode treadmill state: \(String(describing: error), privacy: .public)")
            return .empty(500, "Error")
        }
    }
    
    private func connectionState() -> HttpResponse {
        let state: String
        if !self.walkingPadService.isConnected() {
            state = "disconnected"
        } else if (self.walkingPadService.lastStatus()?.speed ?? 0) > 0 {
            state = "running"
        } else {
            state = "idle"
        }
        do {
            return .json(200, "OK", try JSONEncoder().encode(ConnectionState(state: state)))
        } catch {
            Self.logger.error("Failed to encode connection state: \(String(describing: error), privacy: .public)")
            return .empty(500, "Error")
        }
    }
    
    private func workouts() -> HttpResponse {
        let workouts = self.workout.loadAll().map { entry in
            WorkoutApiData(
                steps: entry.steps,
                distance: entry.distance,
                walkingSeconds: entry.walkingSeconds,
                date: self.dateFormatter.string(from: entry.date)
            )
        }
        do {
            return .json(200, "OK", try JSONEncoder().encode(workouts))
        } catch {
            Self.logger.error("Failed to encode workouts: \(String(describing: error), privacy: .public)")
            return .empty(500, "Error")
        }
    }
    
    private func withCommand(_ action: (WalkingPadCommand) -> Void) -> HttpResponse {
        guard let command = self.walkingPadService.command() else {
            return .empty(428, "Treadmill not connected")
        }
        action(command)
        return .empty(200, "OK")
    }
}

@discardableResult
func startHttpServer(walkingPadService: WalkingPadService, workout: Workout) -> HttpApi? {
    do {
        let server = try HttpApi(walkingPadService: walkingPadService, workout: workout)
        server.start()
        return server
    } catch {
        Logger(subsystem: "klassm.walkingpad-client", category: "http").error("Failed to start HTTP server: \(String(describing: error), privacy: .public)")
        return nil
    }
}
