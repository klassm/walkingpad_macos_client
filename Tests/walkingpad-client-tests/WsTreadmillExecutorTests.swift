import XCTest
@testable import walkingpad_client

// Maps WsAction onto the treadmill's BLE command surface (parity with the
// HTTP API's faster/slower/start/stop semantics).

final class RecordingCommand: WalkingPadCommanding {
    private(set) var calls: [String] = []

    func start() { calls.append("start") }

    func setSpeed(speed: UInt8) { calls.append("setSpeed(\(speed))") }

    func setWalkingMode(mode: WalkingMode) { calls.append("setMode(\(mode))") }

    func updateStatus() { calls.append("updateStatus") }
}

final class StubTreadmill: WsTreadmillControlling {
    var commandToReturn: WalkingPadCommanding?
    var status: DeviceState?

    func command() -> WalkingPadCommanding? { commandToReturn }
    func lastStatus() -> DeviceState? { status }
}

final class WsTreadmillExecutorTests: XCTestCase {
    private var treadmill: StubTreadmill!
    private var command: RecordingCommand!
    private var snapshotItems: [WsWorkoutData]!

    override func setUp() {
        super.setUp()
        treadmill = StubTreadmill()
        command = RecordingCommand()
        treadmill.commandToReturn = command
        snapshotItems = []
    }

    private func makeExecutor() -> WsTreadmillExecutor {
        WsTreadmillExecutor(treadmill: treadmill, snapshotProvider: { self.snapshotItems })
    }

    private func runSync(_ action: WsAction) -> WsExecutionOutcome {
        var outcome: WsExecutionOutcome?
        makeExecutor().execute(action) { outcome = $0 }
        return outcome!
    }

    func testDisconnectedReportsNoConnection() {
        treadmill.commandToReturn = nil
        if case .failure(let code) = runSync(.start) {
            XCTAssertEqual(code, "no-connection")
        } else {
            XCTFail("expected failure outcome")
        }
        XCTAssertEqual(command.calls, [])
    }

    func testStartExecutesBeltStart() {
        XCTAssertEqual(runSync(.start), .complete)
        XCTAssertEqual(command.calls, ["start"])
    }

    func testStopSetsSpeedZero() {
        XCTAssertEqual(runSync(.stop), .complete)
        XCTAssertEqual(command.calls, ["setSpeed(0)"])
    }

    func testFasterIncreasesSpeedByFive() {
        treadmill.status = makeState(speed: 30)
        runSync(.faster)
        XCTAssertEqual(command.calls, ["setSpeed(35)"])
    }

    func testFasterCapsAtEightKmh() {
        treadmill.status = makeState(speed: 79)
        runSync(.faster)
        XCTAssertEqual(command.calls, ["setSpeed(80)"])
    }

    func testFasterWithoutStatusStartsBelt() {
        treadmill.status = nil
        runSync(.faster)
        XCTAssertEqual(command.calls, ["start"])
    }

    func testSlowerDecreasesSpeedByFive() {
        treadmill.status = makeState(speed: 42)
        runSync(.slower)
        XCTAssertEqual(command.calls, ["setSpeed(37)"])
    }

    func testSlowerBelowHalfKmhStopsBelt() {
        treadmill.status = makeState(speed: 3)
        runSync(.slower)
        XCTAssertEqual(command.calls, ["setSpeed(0)"])
    }

    /// Exact boundary: speed 5 has nothing left to decrease by 0.5 km/h, speed 6 does.
    func testSlowerAtFiveBoundaryStopsBelt() {
        treadmill.status = makeState(speed: 5)
        runSync(.slower)
        XCTAssertEqual(command.calls, ["setSpeed(0)"])
    }

    func testSlowerAtSixDecreasesToOne() {
        treadmill.status = makeState(speed: 6)
        runSync(.slower)
        XCTAssertEqual(command.calls, ["setSpeed(1)"])
    }

    func testSlowerWithoutStatusStopsBelt() {
        treadmill.status = nil
        runSync(.slower)
        XCTAssertEqual(command.calls, ["setSpeed(0)"])
    }

    func testSetSpeedPassthrough() {
        runSync(.setSpeed(45))
        XCTAssertEqual(command.calls, ["setSpeed(45)"])
    }

    func testSetWalkingModeMapsToWalkingMode() {
        runSync(.setWalkingMode(.automatic))
        runSync(.setWalkingMode(.manual))
        XCTAssertEqual(command.calls, ["setMode(automatic)", "setMode(manual)"])
    }

    func testSnapshotRepliesWithWorkoutItems() {
        snapshotItems = [WsWorkoutData(date: "2026-10-24", steps: 100, distance: 80, walkingSeconds: 60)]
        let outcome = runSync(.snapshot)
        guard case let .reply(.workouts(items)) = outcome else {
            XCTFail("expected workouts reply, got \(outcome)")
            return
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].steps, 100)
        XCTAssertEqual(command.calls, [])
    }

    private func makeState(speed: Int) -> DeviceState {
        DeviceState(
            time: Date(),
            walkingTimeSeconds: 0,
            speed: speed,
            steps: 0,
            distance: 0,
            walkingMode: .manual,
            deviceName: "test",
            statusType: .currentStatus
        )
    }
}
