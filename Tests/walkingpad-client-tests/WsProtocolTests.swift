import XCTest
@testable import walkingpad_client

final class WsProtocolTests: XCTestCase {

    // MARK: - Dispatcher: valid commands

    func testDispatchStartCommand() throws {
        let data = Data(#"{"id": 1, "type": "start"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .action(id: 1, action: .start))
    }

    func testDispatchStopCommand() {
        let data = Data(#"{"id": 2, "type": "stop"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .action(id: 2, action: .stop))
    }

    func testDispatchFasterAndSlower() {
                XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 3, "type": "faster"}"#.utf8)), .action(id: 3, action: .faster))
        XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 4, "type": "slower"}"#.utf8)), .action(id: 4, action: .slower))
    }

    func testDispatchSetSpeedMapsToDeciKmhUnits() {
        let data = Data(#"{"id": 5, "type": "setSpeed", "speedKmh": 4.5}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .action(id: 5, action: .setSpeed(45)))
    }

    func testSpeedUnitsBoundariesAndRounding() {
        XCTAssertEqual(speedUnits(fromKmh: 1.0), 10)
        XCTAssertEqual(speedUnits(fromKmh: 8.0), 80)
        XCTAssertEqual(speedUnits(fromKmh: 4.46), 45)    // rounds to nearest 0.1 km/h step
        XCTAssertNil(speedUnits(fromKmh: 0.9), "below minimum speed must be rejected")
        XCTAssertNil(speedUnits(fromKmh: 8.1), "above maximum speed must be rejected")
        XCTAssertNil(speedUnits(fromKmh: -1.0), "negative speed must be rejected")
    }

    func testDispatchSetModeValid() {
                XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 6, "type": "setMode", "walkingMode": "manual"}"#.utf8)),
                       .action(id: 6, action: .setWalkingMode(.manual)))
        XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 7, "type": "setMode", "walkingMode": "automatic"}"#.utf8)),
                       .action(id: 7, action: .setWalkingMode(.automatic)))
    }

    func testWalkingModeMappingFromDeviceState() {
        XCTAssertEqual(WsWalkingMode(WalkingMode.manual), .manual)
        XCTAssertEqual(WsWalkingMode(WalkingMode.automatic), .automatic)
    }

    // MARK: - Dispatcher: invalid commands

    /// Numbers and ids may arrive JSON-string-encoded; the dispatcher accepts both.
    func testDispatchAcceptsStringCoercedNumbers() {
        XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": "4", "type": "start"}"#.utf8)),
                       .action(id: 4, action: .start))
        XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 5, "type": "setSpeed", "speedKmh": "4.5"}"#.utf8)),
                       .action(id: 5, action: .setSpeed(45)))
    }

    func testDispatchSnapshot() {
        XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 21, "type": "snapshot"}"#.utf8)),
                       .action(id: 21, action: .snapshot))
    }

    func testDispatchSetSpeedOutOfRangeIsRejected() {
                XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 8, "type": "setSpeed", "speedKmh": 0.9}"#.utf8)),
                       .failure(id: 8, code: "invalid-speed"))
        XCTAssertEqual(WsDispatcher.dispatch(Data(#"{"id": 9, "type": "setSpeed", "speedKmh": 8.5}"#.utf8)),
                       .failure(id: 9, code: "invalid-speed"))
    }

    func testDispatchSetSpeedMissingPayloadIsRejected() {
        let data = Data(#"{"id": 10, "type": "setSpeed"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .failure(id: 10, code: "bad-request"))
    }

    func testDispatchSetModeMissingPayloadIsRejected() {
        let data = Data(#"{"id": 12, "type": "setMode"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .failure(id: 12, code: "bad-request"))
        let badMode = Data(#"{"id": 13, "type": "setMode", "walkingMode": "turbo"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(badMode), .failure(id: 13, code: "bad-request"))
    }

    func testDispatchUnknownTypeIsBadRequest() {
        let data = Data(#"{"id": 14, "type": "launchMissiles"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .failure(id: 14, code: "bad-request"))
    }

    func testDispatchMalformedJSONIsBadRequest() {
        let data = Data(#"not json at all"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .failure(id: nil, code: "bad-request"))
    }

    func testDispatchMissingIdIsBadRequest() {
        let data = Data(#"{"type": "start"}"#.utf8)
        XCTAssertEqual(WsDispatcher.dispatch(data), .failure(id: nil, code: "bad-request"))
    }

    // MARK: - Outbound encoding

    private func jsonDict(_ event: WsEvent) throws -> [String: Any] {
        let data = try WsEventEncoding.encode(event)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEncodeAck() throws {
        let dict = try jsonDict(.ack(id: 3))
        XCTAssertEqual(dict["type"] as? String, "ack")
        XCTAssertEqual(dict["id"] as? Int, 3)
    }

    func testEncodeError() throws {
        let dict = try jsonDict(.error(id: 4, code: "not-connected"))
        XCTAssertEqual(dict["type"] as? String, "error")
        XCTAssertEqual(dict["id"] as? Int, 4)
        XCTAssertEqual(dict["code"] as? String, "not-connected")
        let nilID = try jsonDict(.error(id: nil, code: "bad-request"))
        XCTAssertFalse(nilID.keys.contains("id"), "error without id must omit it")
        XCTAssertEqual(nilID["code"] as? String, "bad-request")
    }

    func testEncodeTreadmillEvent() throws {
        let dict = try jsonDict(.treadmill(speed: 4.5, steps: 1234, distance: 890, walkingSeconds: 615, walkingMode: .manual))
        XCTAssertEqual(dict["type"] as? String, "treadmill")
        XCTAssertEqual(dict["speed"] as? Double, 4.5)
        XCTAssertEqual(dict["steps"] as? Int, 1234)
        XCTAssertEqual(dict["distance"] as? Int, 890)
        XCTAssertEqual(dict["walkingSeconds"] as? Int, 615)
        XCTAssertEqual(dict["walkingMode"] as? String, "manual")
    }

    func testEncodeWorkoutEvent() throws {
        let dict = try jsonDict(.workout(steps: 100, distance: 70, walkingSeconds: 60))
        XCTAssertEqual(dict["type"] as? String, "workout")
        XCTAssertEqual(dict["steps"] as? Int, 100)
        XCTAssertEqual(dict["distance"] as? Int, 70)
        XCTAssertEqual(dict["walkingSeconds"] as? Int, 60)
    }

    func testEncodeWorkoutsEvent() throws {
        let dict = try jsonDict(.workouts(items: [WsWorkoutData(date: "yyyy-MM-dd", steps: 1, distance: 2, walkingSeconds: 3)]))
        XCTAssertEqual(dict["type"] as? String, "workouts")
        let items = try XCTUnwrap(dict["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["date"] as? String, "yyyy-MM-dd")
        XCTAssertEqual(items.first?["steps"] as? Int, 1)
        XCTAssertEqual(items.first?["distance"] as? Int, 2)
        XCTAssertEqual(items.first?["walkingSeconds"] as? Int, 3)
    }

    func testEncodeConnectionEvent() throws {
        let dict = try jsonDict(.connection(state: "running"))
        XCTAssertEqual(dict["type"] as? String, "connection")
        XCTAssertEqual(dict["state"] as? String, "running")
    }

    // MARK: - Event throttling helpers

    func testWorkoutThrottleFirstEventIsSent() {
        let throttle = WsWorkoutThrottle()
        XCTAssertTrue(throttle.shouldEmitWorkout(now: Date(timeIntervalSince1970: 100)))
    }

    func testWorkoutThrottleSuppressesInsideWindow() {
        let throttle = WsWorkoutThrottle()
        XCTAssertTrue(throttle.shouldEmitWorkout(now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(throttle.shouldEmitWorkout(now: Date(timeIntervalSince1970: 115)), "inside 30 s window must stay silent")
        XCTAssertTrue(throttle.shouldEmitWorkout(now: Date(timeIntervalSince1970: 131)), "outside 30 s window must emit")
    }

    func testConnectionTrackerEmitsOnChangeOnly() {
        let tracker = WsConnectionTracker()
        XCTAssertTrue(tracker.shouldEmit(state: "idle"))
        XCTAssertFalse(tracker.shouldEmit(state: "idle"), "unchanged state must not be re-emitted")
        XCTAssertTrue(tracker.shouldEmit(state: "running"))
        XCTAssertTrue(tracker.shouldEmit(state: "disconnected"))
    }
}
