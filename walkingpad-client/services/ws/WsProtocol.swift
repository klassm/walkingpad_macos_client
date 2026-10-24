import Foundation

// WebSocket protocol messages for the walkingpad client (design: websocket.html §6):
// event encoding, command dispatch, speed-unit conversion, and the emission
// throttle/dedup helpers shared by the app layer and WebSocketApi.

public enum WsWalkingMode: String, Equatable, Codable {
    case manual, automatic

    /// Maps the client's DeviceState walking mode onto the protocol enum.
    public init(_ mode: WalkingMode) {
        switch mode {
        case .manual: self = .manual
        case .automatic: self = .automatic
        }
    }
}

public enum WsAction: Equatable {
    case start
    case stop
    case faster
    case slower
    case setSpeed(UInt8)
    case setWalkingMode(WsWalkingMode)
    case snapshot
}

public enum WsDispatch: Equatable {
    case action(id: Int, action: WsAction)
    case failure(id: Int?, code: String)
}

/// Stateless command parser: converts an incoming command frame into a
/// validated action (or failure code). Never executes anything — the transport
/// layer decides how to execute the returned action (reporting ack/error itself).
public enum WsDispatcher {
    /// Parses an incoming command frame and validates it against the treadmill's
    /// actuator constraints.
    public static func dispatch(_ data: Data) -> WsDispatch {
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(id: nil, code: "bad-request")
            }
            object = parsed
        } catch {
            return .failure(id: nil, code: "bad-request")
        }

        guard let id = Self.intValue(object["id"]) else {
            return .failure(id: nil, code: "bad-request")
        }
        guard let type = object["type"] as? String else {
            return .failure(id: id, code: "bad-request")
        }

        switch type {
        case "start":
            return .action(id: id, action: .start)
        case "stop":
            return .action(id: id, action: .stop)
        case "faster":
            return .action(id: id, action: .faster)
        case "slower":
            return .action(id: id, action: .slower)
        case "snapshot":
            return .action(id: id, action: .snapshot)
        case "setSpeed":
            guard let kmh = Self.doubleValue(object["speedKmh"]), let units = speedUnits(fromKmh: kmh) else {
                return .failure(id: id, code: object["speedKmh"] == nil ? "bad-request" : "invalid-speed")
            }
            return .action(id: id, action: .setSpeed(units))
        case "setMode":
            guard let mode = (object["walkingMode"] as? String).flatMap(WsWalkingMode.init(rawValue:)) else {
                return .failure(id: id, code: "bad-request")
            }
            return .action(id: id, action: .setWalkingMode(mode))
        default:
            return .failure(id: id, code: "bad-request")
        }
    }

    /// Accepts numbers, numbers encoded as strings, and integral values
    /// (SwiftPM 5-style JSON decoding tolerances handled manually).
    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

/// A web client may send 1.0–8.0 km/h at 0.1 km/h granularity; the treadmill
/// protocol speaks 0.1 km/h units (UInt8) in the same numeric range.
public func speedUnits(fromKmh kmh: Double) -> UInt8? {
    let units = (kmh * 10).rounded()
    guard units >= 10, units <= 80 else { return nil }
    return UInt8(units)
}

/// A workout-history entry as served in `workouts` events (same shape as the
/// REST DTO `WorkoutApiData`; named with the codebase's `*Data` suffix).
public struct WsWorkoutData: Equatable {
    public var date: String
    public var steps: Int
    public var distance: Int
    public var walkingSeconds: Int

    public init(date: String, steps: Int, distance: Int, walkingSeconds: Int) {
        self.date = date
        self.steps = steps
        self.distance = distance
        self.walkingSeconds = walkingSeconds
    }
}

public enum WsEvent: Equatable {
    case treadmill(speed: Double, steps: Int, distance: Int, walkingSeconds: Int, walkingMode: WsWalkingMode)
    case workout(steps: Int, distance: Int, walkingSeconds: Int)
    case workouts(items: [WsWorkoutData])
    case connection(state: String)
    case ack(id: Int)
    case error(id: Int?, code: String)
}

public enum WsEventEncoding {
    public static func encode(_ event: WsEvent) throws -> Data {
        var object: [String: Any]
        switch event {
        case let .ack(id):
            object = ["type": "ack", "id": id]
        case let .error(id, code):
            object = ["type": "error", "code": code]
            if let id {
                object["id"] = id
            }
        case let .treadmill(speed, steps, distance, walkingSeconds, walkingMode):
            object = [
                "type": "treadmill",
                "speed": speed,
                "steps": steps,
                "distance": distance,
                "walkingSeconds": walkingSeconds,
                "walkingMode": walkingMode.rawValue,
            ]
        case let .workout(steps, distance, walkingSeconds):
            object = [
                "type": "workout",
                "steps": steps,
                "distance": distance,
                "walkingSeconds": walkingSeconds,
            ]
        case let .workouts(items):
            object = [
                "type": "workouts",
                "items": items.map { item in
                    ["date": item.date, "steps": item.steps, "distance": item.distance, "walkingSeconds": item.walkingSeconds]
                },
            ]
        case let .connection(state):
            object = ["type": "connection", "state": state]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Caps workout-total emissions at one every 30 s (mirrors the MQTT heartbeat
/// policy in MqttService.shouldSend()). Thread-safe: broadcasts may originate
/// from different queues.
public final class WsWorkoutThrottle {
    private let lock = NSLock()
    private var lastEmit: Date?

    public init() {}

    public func shouldEmitWorkout(now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastEmit, now.timeIntervalSince(lastEmit) <= 30 {
            return false
        }
        lastEmit = now
        return true
    }
}

/// Suppresses repeated identical connection states — a state change is pushed,
/// never a no-op heartbeat. Thread-safe.
public final class WsConnectionTracker {
    private let lock = NSLock()
    private var lastState: String?

    public init() {}

    public func shouldEmit(state: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != lastState else { return false }
        lastState = state
        return true
    }
}
