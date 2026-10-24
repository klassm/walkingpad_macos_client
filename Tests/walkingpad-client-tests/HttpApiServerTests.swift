import XCTest
@testable import walkingpad_client

// The HTTP API runs on the same proven BSD-sockets transport as the WebSocket
// server (NWListener became unusable inside the App Sandbox — listener never
// became ready, connection refused on 4934). Tests cover the routing logic via
// stubbed dependencies and a real end-to-end request via URLSession.

private final class RecordingHttpCommand: WalkingPadCommanding {
    private(set) var calls: [String] = []

    func start() { calls.append("start") }
    func setSpeed(speed: UInt8) { calls.append("setSpeed(\(speed))") }
    func setWalkingMode(mode: WalkingMode) { calls.append("setMode(\(mode))") }
    func updateStatus() { calls.append("updateStatus") }
}

private final class StubHttpTreadmill: HttpTreadmillProviding {
    var commandToReturn: WalkingPadCommanding?
    var status: DeviceState?
    var connected = false

    func command() -> WalkingPadCommanding? { commandToReturn }
    func lastStatus() -> DeviceState? { status }
    func isConnected() -> Bool { connected }
}

private final class StubHttpWorkout: HttpWorkoutProviding {
    var steps = 123
    var distance = 456
    var walkingSeconds = 78
    var entries: [WorkoutSaveData] = []

    func loadAll() -> [WorkoutSaveData] { entries }
}

final class HttpApiServerTests: XCTestCase {
    private var treadmill: StubHttpTreadmill!
    private var command: RecordingHttpCommand!
    private var workout: StubHttpWorkout!

    override func setUp() {
        super.setUp()
        treadmill = StubHttpTreadmill()
        command = RecordingHttpCommand()
        workout = StubHttpWorkout()
    }

    private func makeApi() -> HttpApi {
        HttpApi(treadmill: treadmill, workout: workout, port: 0)
    }

    private func makeStatus(speed: Int) -> DeviceState {
        DeviceState(time: Date(), walkingTimeSeconds: 0, speed: speed, steps: 0, distance: 0, walkingMode: .manual, deviceName: "test", statusType: .currentStatus)
    }

    // MARK: routing

    func testConnectionRouteReturnsStateJsonWithCorsHeader() throws {
        treadmill.connected = true
        treadmill.status = makeStatus(speed: 52)
        let response = makeApi().handle(method: "GET", path: "/treadmill/connection")
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.serialized().range(of: Data("access-control-allow-origin: *".utf8)) != nil)
        let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(body.contains("\"state\":\"running\""), body)
    }

    func testTreadmillRouteReturnsSnapshot() throws {
        treadmill.status = makeStatus(speed: 30)
        let response = makeApi().handle(method: "GET", path: "/treadmill")
        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(body.contains("\"speed\":3"), body)
        XCTAssertTrue(body.contains("\"steps\":123"), body)
    }

    func testWorkoutsRouteReturnsEntries() throws {
        workout.entries = [WorkoutSaveData(steps: 10, distance: 20, walkingSeconds: 30, date: Date(timeIntervalSince1970: 0))]
        let response = makeApi().handle(method: "GET", path: "/treadmill/workouts")
        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(body.contains("\"steps\":10"), body)
    }

    func testStartWithoutCommandReturns428() {
        treadmill.commandToReturn = nil
        let response = makeApi().handle(method: "POST", path: "/treadmill/start")
        XCTAssertEqual(response.status, 428)
    }

    func testStartExecutesCommand() {
        treadmill.commandToReturn = command
        let response = makeApi().handle(method: "POST", path: "/treadmill/start")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(command.calls, ["start"])
    }

    func testSpeedRouteValidatesValue() {
        treadmill.commandToReturn = command
        XCTAssertEqual(makeApi().handle(method: "POST", path: "/treadmill/speed/40").status, 200)
        XCTAssertEqual(command.calls, ["setSpeed(40)"])
        // 45 is not a multiple of 10 → 404
        XCTAssertEqual(makeApi().handle(method: "POST", path: "/treadmill/speed/45").status, 404)
        XCTAssertEqual(makeApi().handle(method: "POST", path: "/treadmill/speed/90").status, 404)
    }

    func testUnknownRouteReturns404() {
        XCTAssertEqual(makeApi().handle(method: "GET", path: "/nope").status, 404)
    }

    // MARK: request parsing

    func testParseRequestReadsHeadersAndContentLength() {
        let request = Data("POST /treadmill/start HTTP/1.1\r\ncontent-length: 0\r\n\r\n".utf8)
        let parsed = HttpApi.parseRequest(from: request)
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(parsed?.path, "/treadmill/start")
        XCTAssertEqual(parsed?.totalLength, request.count)
    }

    func testParseRequestReturnsNilWhileIncomplete() {
        XCTAssertNil(HttpApi.parseRequest(from: Data("GET / HTTP/1.1\r\n".utf8)))
    }

    // MARK: end-to-end over a real socket

    func testServerAnswersRealHttpRequestOnLoopback() throws {
        treadmill.connected = true
        treadmill.status = makeStatus(speed: 0)
        let api = makeApi()
        try api.start()
        defer { api.stop() }
        let port = try XCTUnwrap(api.boundPort())

        let expectation = expectation(description: "response")
        var result: (HTTPURLResponse, Data)?
        let task = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/treadmill/connection")!) { data, response, _ in
            if let http = response as? HTTPURLResponse, let data { result = (http, data) }
            expectation.fulfill()
        }
        task.resume()
        wait(for: [expectation], timeout: 5)

        let (http, data) = try XCTUnwrap(result)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "access-control-allow-origin"), "*")
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"state\":\"idle\"") == true)
    }
}
