import Foundation

// Executes WsActions on the real treadmill (design: websocket.html §6).
// Semantics mirror the HTTP API's command routes (HttpApi.swift) so both
// transports behave identically:
//  - disconnected → failure "no-connection"
//  - faster/slower step ±5 units (0.5 km/h), clamped to 0–80; without a known
//    status, faster starts the belt and slower stops it.
// Note on acks: a BLE write via writeValue(.withoutResponse) is fire-and-forget,
// so `.complete`/`ack` means "queued for the treadmill", not "confirmed by it".
public protocol WsTreadmillControlling {
    func command() -> WalkingPadCommanding?
    func lastStatus() -> DeviceState?
}

extension WalkingPadService: WsTreadmillControlling {}

public final class WsTreadmillExecutor: WsCommandExecuting {
    private let treadmill: WsTreadmillControlling
    private let snapshotProvider: () -> [WsWorkoutData]

    public init(treadmill: WsTreadmillControlling, snapshotProvider: @escaping () -> [WsWorkoutData] = { [] }) {
        self.treadmill = treadmill
        self.snapshotProvider = snapshotProvider
    }

    public func execute(_ action: WsAction, completion: @escaping (WsExecutionOutcome) -> Void) {
        guard action != .snapshot else {
            completion(.reply(.workouts(items: snapshotProvider())))
            return
        }
        guard let command = treadmill.command() else {
            completion(.failure(code: "no-connection"))
            return
        }

        switch action {
        case .start:
            command.start()
        case .stop:
            command.setSpeed(speed: 0)
        case .faster:
            faster(command)
        case .slower:
            slower(command)
        case .setSpeed(let units):
            command.setSpeed(speed: units)
        case .setWalkingMode(let mode):
            command.setWalkingMode(mode: mode == .manual ? .manual : .automatic)
        case .snapshot:
            break // handled above
        }
        completion(.complete)
    }

    private func faster(_ command: WalkingPadCommanding) {
        guard let current = treadmill.lastStatus() else {
            command.start()
            return
        }
        command.setSpeed(speed: UInt8(min(80, current.speed + 5)))
    }

    private func slower(_ command: WalkingPadCommanding) {
        guard let current = treadmill.lastStatus(), current.speed > 5 else {
            command.setSpeed(speed: 0)
            return
        }
        command.setSpeed(speed: UInt8(current.speed - 5))
    }
}
