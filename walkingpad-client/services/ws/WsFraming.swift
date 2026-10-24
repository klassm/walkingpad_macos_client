import Foundation
import CommonCrypto

// RFC 6455 handshake helpers for the loopback WebSocket server (design: websocket.html §5).

public enum WsHandshakeError: Error {
    case notWebSocketUpgrade
}

public struct WsHandshake {
    public struct ParsedRequest {
        public let path: String
        public let key: String
    }

    static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func acceptKey(forKey: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let material = Data((forKey + webSocketGUID).utf8)
        material.withUnsafeBytes { pointer in
            _ = CC_SHA1(pointer.baseAddress, CC_LONG(material.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }

    /// Parses a client HTTP upgrade request; nil when it is no valid WebSocket upgrade.
    /// Host must be loopback (anti-DNS-rebinding hardening; not an auth mechanism).
    public static func parse(_ request: String) -> ParsedRequest? {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              requestLine.hasPrefix("GET "),
              requestLine.hasSuffix(" HTTP/1.1") else {
            return nil
        }
        let path = String(requestLine.dropFirst("GET ".count).dropLast(" HTTP/1.1".count))

        var upgrade = false
        var key: String?
        var loopbackHost = false
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch name {
            case "upgrade":
                upgrade = value.lowercased() == "websocket"
            case "sec-websocket-key":
                key = value
            case "host":
                // Accept "127.0.0.1[:port]" and "localhost[:port]" only.
                let host = value.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                loopbackHost = host == "127.0.0.1" || host == "localhost"
            default:
                break
            }
        }
        guard upgrade, loopbackHost, let secKey = key, !secKey.isEmpty else { return nil }
        return ParsedRequest(path: path, key: secKey)
    }

    public static func response(acceptKey: String) -> String {
        "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(acceptKey)\r\n" +
            "\r\n"
    }
}

public enum WsOpcode: UInt8 {
    case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
}

public struct WsIncomingFrame: Equatable {
    public let opcode: WsOpcode
    public let final: Bool
    public let payload: Data
}

/// Incremental RFC 6455 frame decoder for the server (client) side: requires
/// masked-payload frames (as real WS clients must send), unmasks them, joins
/// continuation frames into complete messages, and fails the connection with a
/// close code on protocol violations or oversized payloads.
public struct WsFrameDecoder {
    /// Guards against hostile length declarations / unbounded accumulation;
    /// command payloads are well under 1 KB of JSON by design.
    public static let maximumMessageLength = 1_000_000

    private static let closeProtocolError: UInt16 = 1002
    private static let closeMessageTooBig: UInt16 = 1009

    private static func closePayload(code: UInt16) -> Data {
        Data([UInt8(code >> 8), UInt8(code & 0xFF)])
    }

    private var buffer = Data()
    private var pendingMessage: (opcode: WsOpcode, payload: Data)?

    public init() {}

    /// Bytes still waiting to be decoded (internal, for tests).
    var bufferedByteCount: Int { buffer.count }

    public mutating func feed(_ data: Data) -> [WsIncomingFrame] {
        // Normalize to an independent, zero-based buffer: slices fed by callers
        // and in-place trims of large buffers can leave `buffer` with a non-zero
        // startIndex, which would make the index-based decoding below trap.
        if buffer.startIndex != 0 {
            buffer = Data(buffer)
        }
        buffer += data
        var frames: [WsIncomingFrame] = []
        var readOffset = 0
        var protocolError: UInt16?
        while protocolError == nil {
            guard let (opcode, final, payload, consumed, errorCode) = nextFrame(at: readOffset) else { break }
            if let errorCode {
                protocolError = errorCode
                break
            }
            readOffset += consumed
            switch opcode {
            case .continuation:
                guard pendingMessage != nil else {
                    protocolError = Self.closeProtocolError
                    break
                }
                pendingMessage!.payload += payload
                if pendingMessage!.payload.count > Self.maximumMessageLength {
                    pendingMessage = nil
                    protocolError = Self.closeMessageTooBig
                    break
                }
                if final {
                    let merged = WsIncomingFrame(opcode: pendingMessage!.opcode, final: true, payload: pendingMessage!.payload)
                    pendingMessage = nil
                    frames.append(merged)
                }
            case .text, .binary:
                if final {
                    frames.append(WsIncomingFrame(opcode: opcode, final: true, payload: payload))
                } else {
                    pendingMessage = (opcode, payload)
                }
            case .ping, .pong, .close:
                frames.append(WsIncomingFrame(opcode: opcode, final: final, payload: payload))
            }
        }
        if let protocolError {
            frames.append(WsIncomingFrame(opcode: .close, final: true, payload: Self.closePayload(code: protocolError)))
            // The connection ends here: nothing further may be decoded.
            buffer.removeAll()
            pendingMessage = nil
        } else if readOffset > 0 {
            // Rebase to a fresh zero-based Data instead of removeFirst(_:):
            // trimming a large buffer in place and appending later can leave
            // the Data with a stale startIndex, trapping index-based access.
            buffer = Data(buffer.dropFirst(readOffset))
        }
        return frames
    }

    /// Attempts to decode one frame starting at `offset`; nil while incomplete.
    /// The fifth tuple element carries the RFC close code when the frame must
    /// fail the connection (protocol error / oversize); consumed bytes are then
    /// meaningless (the whole buffer is dropped).
    private func nextFrame(at offset: Int) -> (opcode: WsOpcode, final: Bool, payload: Data, consumed: Int, errorCode: UInt16?)? {
        guard buffer.count >= offset + 2 else { return nil }
        let first = buffer[offset]
        let second = buffer[offset + 1]
        let masked = second & 0x80 != 0

        // RFC 6455 §5.1: client-to-server frames MUST be masked.
        guard masked else {
            return (.close, true, Data(), 0, Self.closeProtocolError)
        }
        guard let opcode = WsOpcode(rawValue: first & 0x0F) else {
            return (.close, true, Data(), 0, Self.closeProtocolError)
        }

        var payloadLength = UInt64(second & 0x7F)
        var headerLength = 2
        switch second & 0x7F {
        case 126:
            guard buffer.count >= offset + 4 else { return nil }
            payloadLength = UInt64(buffer[offset + 2]) << 8 | UInt64(buffer[offset + 3])
            headerLength = 4
        case 127:
            guard buffer.count >= offset + 10 else { return nil }
            payloadLength = (0..<8).reduce(0) { ($0 << 8) | UInt64(buffer[offset + 2 + $1]) }
            headerLength = 10
        default:
            break
        }
        // Declared size is checked in UInt64 space before any Int conversion —
        // a hostile header can no longer trap on integer overflow.
        if payloadLength > UInt64(Self.maximumMessageLength) {
            return (opcode, true, Data(), 0, Self.closeMessageTooBig)
        }

        guard buffer.count >= offset + headerLength + 4 else { return nil }
        let maskKey = Array(buffer[(offset + headerLength)..<(offset + headerLength + 4)])

        let length = Int(payloadLength)
        let total = headerLength + 4 + length
        guard buffer.count >= offset + total else { return nil }
        var payload = Data(buffer[(offset + headerLength + 4)..<(offset + total)])
        for index in 0..<length {
            payload[index] ^= maskKey[index % 4]
        }
        return (opcode, first & 0x80 != 0, payload, total, nil)
    }
}

/// Server-side frame encoder: emits unmasked, FIN-only frames.
public enum WsFrameEncoder {
    public static func encode(_ opcode: WsOpcode, payload: Data) -> Data {
        var bytes = Data()
        bytes.append(0x80 | opcode.rawValue)
        let count = payload.count
        if count <= 125 {
            bytes.append(UInt8(count))
        } else if count <= 0xFFFF {
            bytes.append(126)
            bytes.append(UInt8((count >> 8) & 0xFF))
            bytes.append(UInt8(count & 0xFF))
        } else {
            bytes.append(127)
            var remaining = UInt64(count)
            var lengthBytes: [UInt8] = []
            for _ in 0..<8 {
                lengthBytes.append(UInt8(remaining & 0xFF))
                remaining >>= 8
            }
            bytes.append(contentsOf: lengthBytes.reversed())
        }
        bytes += payload
        return bytes
    }
}
