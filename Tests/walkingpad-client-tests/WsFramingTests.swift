import XCTest
@testable import walkingpad_client

final class WsFramingTests: XCTestCase {
    // MARK: - Handshake

    /// RFC 6455 §1.3 example.
    func testAcceptKeyMatchesRFC6455Example() {
        XCTAssertEqual(WsHandshake.acceptKey(forKey: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testHandshakeParsesClientUpgradeRequest() {
        let request = """
        GET /ws HTTP/1.1\r
        Host: 127.0.0.1:59999\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        let parsed = WsHandshake.parse(request)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.path, "/ws")
        XCTAssertEqual(parsed?.key, "dGhlIHNhbXBsZSBub25jZQ==")
    }

    func testHandshakeRejectsPlainHttpRequest() {
        let request = "GET /ws HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertNil(WsHandshake.parse(request))
    }

    /// Cheap anti-DNS-rebinding hardening (not auth): only loopback hosts upgrade.
    func testHandshakeRequiresLoopbackHost() {
        func request(host: String) -> String {
            "GET /ws HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        }
        XCTAssertNil(WsHandshake.parse(request(host: "evil.example.com:4935")))
        XCTAssertNil(WsHandshake.parse(request(host: "evil.example.com")))
        XCTAssertNotNil(WsHandshake.parse(request(host: "127.0.0.1:59999")))
        XCTAssertNotNil(WsHandshake.parse(request(host: "localhost:4935")))
        XCTAssertNil(WsHandshake.parse(request(host: "")))
    }

    func testHandshakeRejectsWebSocketUpgradeWithoutKey() {
        let request = "GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        XCTAssertNil(WsHandshake.parse(request))
    }

    func testHandshakeResponseLineContainsAcceptKey() {
        let response = WsHandshake.response(acceptKey: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(response.contains("Upgrade: websocket\r\n"))
        XCTAssertTrue(response.contains("Connection: Upgrade\r\n"))
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\n"))
    }

    // MARK: - Decoder

    /// Client frames must be masked (RFC 6455 §5.1); the decoder fails the
    /// connection with a 1002 close otherwise.
    func testFailsUnmaskedClientFrameWithProtocolError() {
        var decoder = WsFrameDecoder()
        let frames = decoder.feed(Data([0x81, 0x05]) + Data("hello".utf8))
        XCTAssertEqual(frames, [WsIncomingFrame(opcode: .close, final: true, payload: Data([0x03, 0xEA]))])
        // The failed connection must not keep buffering.
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecodesSingleMaskedTextFrameShape() {
        var masked = Data([0x81, 0x85, 0x01, 0x23, 0x45, 0x67, 0x69, 0x46, 0x29, 0x0B, 0x6E])
        var decoder = WsFrameDecoder()
        let frames = decoder.feed(masked)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].opcode, .text)
        XCTAssertEqual(frames[0].payload, Data("hello".utf8))
        XCTAssertTrue(frames[0].final)
    }

    func testDecodesAndUnmasksClientFrame() {
        // "hello" ^ [0x01,0x23,0x45,0x67] = 0x69 0x46 0x29 0x0B 0x6E.
        var masked = Data([0x81, 0x85, 0x01, 0x23, 0x45, 0x67, 0x69, 0x46, 0x29, 0x0B, 0x6E])
        var decoder = WsFrameDecoder()
        let frames = decoder.feed(masked)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, Data("hello".utf8))
    }

    func testDecoderBuffersPartialChunks() {
        var decoder = WsFrameDecoder()
        // masked "hello", split after 3 header bytes
        let frame = Data([0x81, 0x85, 0x01, 0x23, 0x45, 0x67, 0x69, 0x46, 0x29, 0x0B, 0x6E])
        XCTAssertEqual(decoder.feed(frame[..<3]), [])
        let rest = decoder.feed(frame[3...])
        XCTAssertEqual(rest, [WsIncomingFrame(opcode: .text, final: true, payload: Data("hello".utf8))],
                       "Final chunk must emit exactly the completed frame")
    }

    func testDecoderJoinsFragmentedMessages() {
        var decoder = WsFrameDecoder()
        // Fragment 1: "hel" masked with [0x01,0x23,0x45,0x67] → [0x69,0x46,0x29]
        let first = Data([0x01, 0x83, 0x01, 0x23, 0x45, 0x67, 0x69, 0x46, 0x29])
        // Fragment 2: "lo" masked with [0x02,0x03,0x04,0x05] → l^0x02=0x6E, o^0x03=0x6C
        let second = Data([0x80, 0x82, 0x02, 0x03, 0x04, 0x05, 0x6E, 0x6C])
        let frames = decoder.feed(first + second)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].opcode, .text)
        XCTAssertTrue(frames[0].final)
        XCTAssertEqual(frames[0].payload, Data("hello".utf8))
    }

    func testDecoderAcceptsPingInterleavedWithMessage() {
        var decoder = WsFrameDecoder()
        let frameText = Data([0x81, 0x85, 0x01, 0x23, 0x45, 0x67, 0x69, 0x46, 0x29, 0x0B, 0x6E])
        // Masked ping with empty payload.
        let ping = Data([0x89, 0x80, 0x01, 0x02, 0x03, 0x04])
        let frames = decoder.feed(frameText + ping)
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.contains { $0.opcode == .ping && $0.payload.isEmpty })
    }

    /// Unknown/reserved opcodes must fail the connection (RFC 6455 §5.2) instead
    /// of being silently reinterpreted.
    func testFailsUnknownOpcodeWithProtocolError() {
        var decoder = WsFrameDecoder()
        // Reserved opcode 0x3, masked, single frame.
        let frames = decoder.feed(Data([0x83, 0x80, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(frames, [WsIncomingFrame(opcode: .close, final: true, payload: Data([0x03, 0xEA]))])
    }

    /// A continuation frame with no fragmented message in progress fails the
    /// connection (RFC 6455 §5.4) instead of being dropped.
    func testFailsStrayContinuationFrameWithProtocolError() {
        var decoder = WsFrameDecoder()
        let frames = decoder.feed(Data([0x80, 0x80, 0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(frames, [WsIncomingFrame(opcode: .close, final: true, payload: Data([0x03, 0xEA]))])
    }

    /// A declared length beyond the message cap must produce a 1009 close —
    /// and must never trap on integer overflow (regression for WsFraming).
    func testRejectsOversizedDeclaredLengthWithTooBigClose() {
        var decoder = WsFrameDecoder()
        // FIN+text, masked, 64-bit length form declaring UInt64 max.
        var bytes = Data([0x81, 0xFF])
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        bytes.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // mask key
        bytes.append(Data("hello".utf8)) // payload bytes that must not be absorbed
        let frames = decoder.feed(bytes)
        XCTAssertEqual(frames, [WsIncomingFrame(opcode: .close, final: true, payload: Data([0x03, 0xF1]))])
        // All Garbage-in must be dropped, not buffered while waiting for gigabytes.
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    /// A fragmented message that exceeds the cap fails with 1009 mid-message.
    func testRejectsAccumulatedMessageOverCap() {
        var decoder = WsFrameDecoder()
        var first = Data([0x01, 0xFF]) // text, masked, 64-bit length
        first.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x42, 0x3F]) // 999_999, below the 1 MB cap
        first.append(contentsOf: [0x01, 0x02, 0x03, 0x04])
        let masks: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        first.append(contentsOf: Data(repeating: 0x61, count: 999_999).enumerated().map { $0.element ^ masks[$0.offset % 4] })
        var second = Data([0x80, 0xFE, 0x02, 0xBC]) // continuation, 700 payload
        second.append(contentsOf: masks)
        second.append(contentsOf: Data(repeating: 0x62, count: 700).enumerated().map { $0.element ^ masks[$0.offset % 4] })
        // First fragment is below the cap and buffers silently.
        XCTAssertEqual(decoder.feed(first), [])
        let frames = decoder.feed(second)
        XCTAssertEqual(frames, [WsIncomingFrame(opcode: .close, final: true, payload: Data([0x03, 0xF1]))])
    }

    func testDecoderHandlesMasked16BitLengthPayload() {
        let payload = Data(repeating: 0x61, count: 700)
        let key: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var bytes = Data([0x81, 0xFE, 0x02, 0xBC]) // FIN+text, masked, 16-bit length 700
        bytes.append(contentsOf: key)
        bytes.append(contentsOf: payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
        var decoder = WsFrameDecoder()
        let frames = decoder.feed(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].opcode, .text)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testDecoderHandlesMasked64BitLengthPayload() {
        let payload = Data(repeating: 0x62, count: 70000)
        let key: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var bytes = Data([0x81, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x11, 0x70]) // FIN+text, masked, 64-bit length 70000
        bytes.append(contentsOf: key)
        bytes.append(contentsOf: payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
        var decoder = WsFrameDecoder()
        let frames = decoder.feed(bytes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, payload)
    }

    // MARK: - Encoder

    func testEncoderEmitsUnmaskedTextFrameBytes() {
        let frame = WsFrameEncoder.encode(.text, payload: Data("hi".utf8))
        XCTAssertEqual(frame, Data([0x81, 0x02]) + Data("hi".utf8))
    }

    func testEncoderHandles16BitLength() {
        let frame = WsFrameEncoder.encode(.text, payload: Data(repeating: 0x61, count: 700))
        // FIN+text, 16-bit length form (126 = 0x7E), length 700 = 0x02BC big-endian, then the payload.
        XCTAssertEqual(frame.prefix(4), Data([0x81, 0x7E, 0x02, 0xBC]))
        XCTAssertEqual(frame.count, 700 + 4) // 2 header + 2 length + 700 payload (no mask)
        XCTAssertEqual(frame.suffix(700), Data(repeating: 0x61, count: 700))
    }
}
