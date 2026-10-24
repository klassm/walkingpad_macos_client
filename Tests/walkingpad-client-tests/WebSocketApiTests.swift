import XCTest
@testable import walkingpad_client

// Integration tests for the loopback-bound WebSocket transport
// (design §5: BSD-socket server with own RFC 6455 codec; loopback-only binding is
// a hard requirement). Client side uses URLSessionWebSocketTask.

/// Test double: records actions, returns a canned outcome.
final class RecordingExecutor: WsCommandExecuting {
    private let lock = NSLock()
    private(set) var actions: [WsAction] = []
    var outcome: WsExecutionOutcome = .complete

    func execute(_ action: WsAction, completion: @escaping (WsExecutionOutcome) -> Void) {
        lock.lock()
        actions.append(action)
        let current = outcome
        lock.unlock()
        completion(current)
    }

    func recordedActions() -> [WsAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }
}

final class TestWsClient {
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "test.ws-client")

    func connect(port: UInt16) {
        let url = URL(string: "ws://127.0.0.1:\(port)/ws")!
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    /// Receives messages until `count` text messages have arrived; fails the test on timeout.
    func drain(count: Int, timeout: TimeInterval = 5) -> [String] {
        let received = ReceivedCollector(expected: count)
        let task = self.task!
        let group = DispatchGroup()
        func receiveNext(_ remaining: Int) {
            guard remaining > 0 else { return }
            group.enter()
            task.receive { result in
                defer { group.leave() }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        received.append(text)
                        receiveNext(remaining - 1)
                    } else if case .data(let data) = message,
                              let text = String(data: data, encoding: .utf8) {
                        received.append(text)
                        receiveNext(remaining - 1)
                    }
                case .failure:
                    received.append("<<<failure>>>" .trimmingCharacters(in: []))
                }
            }
        }
        receiveNext(count)
        let result = group.wait(timeout: .now() + timeout)
        XCTAssertEqual(result, .success, "Timed out waiting for \(count) WebSocket message(s); got \(received.snapshot())")
        return received.snapshot()
    }

    func send(_ text: String) {
        task?.send(.string(text)) { error in
            if let error {
                XCTFail("Client send failed: \(error)")
            }
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private final class ReceivedCollector {
        private let lock = NSLock()
        private var messages: [String] = []
        private let expected: Int
        init(expected: Int) { self.expected = expected }
        func append(_ text: String) {
            lock.lock()
            messages.append(text)
            lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }
}

final class WebSocketApiTests: XCTestCase {
    private var api: WebSocketApi?
    private var executor: RecordingExecutor?
    private var client: TestWsClient?

    override func tearDown() {
        client?.close()
        api?.stop()
        api = nil
        executor = nil
        client = nil
        super.tearDown()
    }

    private func makeServer(connectionState: @escaping () -> String) -> (WebSocketApi, RecordingExecutor)? {
        let executor = RecordingExecutor()
        let api = WebSocketApi(executor: executor, connectionState: connectionState)
        do {
            try api.start()
        } catch {
            XCTFail("api.start() failed: \(error)")
            return nil
        }
        guard waitFor({ api.boundPort() != nil }), let port = api.boundPort() else {
            XCTFail("Server did not bind a port in time")
            return nil
        }
        self.api = api
        self.executor = executor
        return (api, executor)
    }

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    // MARK: - Binding

    func testStartBindsAnEphemeralLoopbackPort() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        XCTAssertTrue(api.boundPort().map { $0 > 0 } == true, "boundPort not assigned or invalid")
    }

    func testStartBindsTheRequestedFixedPort() {
        let executor = RecordingExecutor()
        let api = WebSocketApi(executor: executor, connectionState: { "idle" }, port: 4_971)
        defer { api.stop() }
        do {
            try api.start()
        } catch {
            XCTFail("api.start() failed: \(error)")
            return
        }
        XCTAssertEqual(api.boundPort(), 4_971, "Server must bind the requested fixed port")
    }

    // MARK: - Events

    func testClientReceivesConnectionStateOnConnect() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"state\":\"idle\",\"type\":\"connection\"}")
    }

    func testBroadcastReachesConnectedClient() {
        guard let (api, _) = makeServer(connectionState: { "running" }) else { return }
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1) // initial connection event
        api.broadcast(.treadmill(speed: 4.5, steps: 1200, distance: 3200, walkingSeconds: 960, walkingMode: .automatic))
        let messages = client.drain(count: 1)
        XCTAssertEqual(
            messages.first,
            "{\"distance\":3200,\"speed\":4.5,\"steps\":1200,\"type\":\"treadmill\",\"walkingMode\":\"automatic\",\"walkingSeconds\":960}"
        )
    }

    func testBroadcastOnlyGoesToLiveConnections() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        api.broadcast(.connection(state: "running"))
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"state\":\"running\",\"type\":\"connection\"}")
    }

    // MARK: - Commands

    func testSnapshotCommandRepliesWorkouts() {
        guard let (api, executor) = makeServer(connectionState: { "idle" }) else { return }
        executor.outcome = .reply(.workouts(items: [
            WsWorkoutData(date: "2026-10-24", steps: 5400, distance: 4100, walkingSeconds: 3600),
        ]))
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        client.send("{\"id\":7,\"type\":\"snapshot\"}")
        let messages = client.drain(count: 1)
        XCTAssertEqual(
            messages.first,
            "{\"items\":[{\"date\":\"2026-10-24\",\"distance\":4100,\"steps\":5400,\"walkingSeconds\":3600}],\"type\":\"workouts\"}"
        )
        XCTAssertEqual(executor.recordedActions(), [.snapshot])
    }

    func testActionCommandRepliesAck() {
        guard let (api, executor) = makeServer(connectionState: { "idle" }) else { return }
        executor.outcome = .complete
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        client.send("{\"id\":3,\"type\":\"start\"}")
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"id\":3,\"type\":\"ack\"}")
        XCTAssertEqual(executor.recordedActions(), [.start])
    }

    func testExecutorFailureReturnsErrorWithId() {
        guard let (api, executor) = makeServer(connectionState: { "idle" }) else { return }
        executor.outcome = .failure(code: "no-connection")
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        client.send("{\"id\":5,\"type\":\"stop\"}")
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"code\":\"no-connection\",\"id\":5,\"type\":\"error\"}")
    }

    func testMalformedCommandReturnsErrorWithoutId() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        client.send("definitely not json")
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"code\":\"bad-request\",\"type\":\"error\"}")
    }

    // MARK: - Self-gating broadcasts (MqttService.publish parity, websocket.html §7)

    func testBroadcastConnectionEmitsOnlyOnStateChange() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        // The initial per-connection event seeded the tracker: an unchanged
        // state must be suppressed.
        api.broadcastConnection(state: "idle")
        api.broadcastConnection(state: "running")
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"state\":\"running\",\"type\":\"connection\"}")
        // And switching back re-emits.
        api.broadcastConnection(state: "idle")
        let back = client.drain(count: 1)
        XCTAssertEqual(back.first, "{\"state\":\"idle\",\"type\":\"connection\"}")
    }

    func testBroadcastWorkoutThrottlesWithinThirtySeconds() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        let client = TestWsClient()
        self.client = client
        client.connect(port: api.boundPort()!)
        _ = client.drain(count: 1)
        let first = Date()
        let later1 = first.addingTimeInterval(15)
        let later2 = first.addingTimeInterval(31.5)
        api.broadcastWorkout(event: .workout(steps: 1, distance: 2, walkingSeconds: 3), now: first) // first: emitted
        api.broadcastWorkout(event: .workout(steps: 4, distance: 5, walkingSeconds: 6), now: later1) // inside window: suppressed
        api.broadcastWorkout(event: .workout(steps: 7, distance: 8, walkingSeconds: 9), now: later2) // outside window: emitted
        let messages = client.drain(count: 2)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last, "{\"distance\":8,\"steps\":7,\"type\":\"workout\",\"walkingSeconds\":9}")
    }

    // MARK: - Resilience

    /// A plain HTTP request to the WS port must not wedge the server: a real
    /// WS client connecting afterwards still works (stale-connection cleanup).
    func testServerSurvivesPlainHttpProbeThenServesWebSocket() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        guard let port = api.boundPort() else { return }
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let expectation = expectation(description: "plain http probe completed")
        var probeDone = false
        URLSession.shared.dataTask(with: url) { _, _, _ in
            probeDone = true
            expectation.fulfill()
        }.resume()
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(probeDone)
        // Give the connection thread a moment to run its failed handshake cleanup.
        Thread.sleep(forTimeInterval: 0.3)
        let client = TestWsClient()
        self.client = client
        client.connect(port: port)
        let messages = client.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"state\":\"idle\",\"type\":\"connection\"}")
    }

    // MARK: - CORS private-network preflight (Chrome 147+ LNA for WebSockets)

    /// Chrome 147+ gates WebSocket connections behind Local Network Access and
    /// probes the port with an OPTIONS preflight first. The server must answer
    /// it (204 + CORS + private-network header) instead of failing the upgrade.
    func testAnswersCorsPreflightOnWebSocketPort() {
        guard let (api, _) = makeServer(connectionState: { "idle" }) else { return }
        guard let port = api.boundPort() else { return }
        let client = TestRawHttpClient()
        let response = client.roundTrip(
            port: port,
            request: "OPTIONS /ws HTTP/1.1\r\n" +
                "Host: 127.0.0.1:\(port)\r\n" +
                "Origin: https://walkingpad-stats.netlify.app\r\n" +
                "Access-Control-Request-Method: GET\r\n" +
                "Access-Control-Request-Private-Network: true\r\n" +
                "\r\n"
        )
        guard let response else {
            XCTFail("No response to OPTIONS preflight")
            return
        }
        XCTAssertTrue(response.contains("204"), "expected 204, got: \(response)")
        XCTAssertTrue(response.contains("access-control-allow-private-network: true"), "missing private-network header: \(response)")
        XCTAssertTrue(response.contains("access-control-allow-origin: *"), "missing CORS origin header: \(response)")
        // The server must still serve WebSocket upgrades afterwards.
        let ws = TestWsClient()
        self.client = ws
        ws.connect(port: port)
        let messages = ws.drain(count: 1)
        XCTAssertEqual(messages.first, "{\"state\":\"idle\",\"type\":\"connection\"}")
    }
}

/// Minimal raw TCP client for non-WebSocket HTTP probes (preflight tests).
final class TestRawHttpClient {
    /// Sends `request` verbatim to 127.0.0.1:port; returns the response text
    /// (headers + body) the server sends back before closing, or nil.
    func roundTrip(port: UInt16, request: String, timeout: TimeInterval = 5) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        let data = Data(request.utf8)
        let sent = data.withUnsafeBytes { pointer -> Bool in
            pointer.baseAddress.map { send(fd, $0, data.count, 0) >= 0 } ?? false
        }
        guard sent else { return nil }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received += buffer[0..<n]
        }
        return String(data: received, encoding: .utf8)
    }
}
