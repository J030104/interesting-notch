import CryptoKit
import Foundation

/// Codex's Unix-socket proxy carries WebSocket bytes, while the private server uses JSON lines.
struct CodexWebSocket {
    enum Event {
        case connected
        case message(Data)
        case ping(Data)
        case closed
    }

    enum InvalidFrame: Error { case invalid }

    private static let maximumSize = 32 * 1024 * 1024
    private let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    private var incoming = Data()
    private var partialText: Data?
    private(set) var isReady = false

    var handshake: Data {
        let headers = [
            "GET / HTTP/1.1", "Host: localhost", "Upgrade: websocket", "Connection: Upgrade",
            "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13", "", ""
        ]
        return Data(headers.joined(separator: "\r\n").utf8)
    }

    mutating func receive(_ bytes: Data) throws -> [Event] {
        incoming.append(bytes)
        var events: [Event] = []
        if !isReady {
            guard let end = incoming.range(of: Data("\r\n\r\n".utf8)) else {
                guard incoming.count <= 16_384 else { throw InvalidFrame.invalid }
                return []
            }
            let response = String(decoding: incoming[..<end.lowerBound], as: UTF8.self)
            let lines = response.components(separatedBy: "\r\n")
            let nonce = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            let accept = Data(Insecure.SHA1.hash(data: Data(nonce.utf8))).base64EncodedString()
            guard lines.first?.split(separator: " ").dropFirst().first == "101",
                  lines.contains(where: { line in
                      let field = line.split(separator: ":", maxSplits: 1)
                      return field.count == 2 && field[0].lowercased() == "sec-websocket-accept"
                          && field[1].trimmingCharacters(in: .whitespaces) == accept
                  }) else { throw InvalidFrame.invalid }
            incoming.removeSubrange(..<end.upperBound)
            isReady = true
            events.append(.connected)
        }

        while let frame = try nextFrame() {
            let (opcode, final, payload) = frame
            switch opcode {
            case 0:
                guard var text = partialText,
                      text.count + payload.count <= Self.maximumSize else { throw InvalidFrame.invalid }
                text.append(payload)
                partialText = final ? nil : text
                if final { events.append(.message(text)) }
            case 1:
                guard partialText == nil else { throw InvalidFrame.invalid }
                if final {
                    events.append(.message(payload))
                } else {
                    partialText = payload
                }
            case 8:
                events.append(.closed)
                return events
            case 9:
                events.append(.ping(payload))
            case 10:
                break
            default:
                throw InvalidFrame.invalid
            }
        }
        return events
    }

    static func frame(_ payload: Data, opcode: UInt8 = 1) -> Data {
        var data = Data([0x80 | opcode])
        if payload.count < 126 {
            data.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            data.append(0xFE)
            var size = UInt16(payload.count).bigEndian
            Swift.withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        } else {
            data.append(0xFF)
            var size = UInt64(payload.count).bigEndian
            Swift.withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        data.append(contentsOf: mask)
        data.reserveCapacity(data.count + payload.count)
        for (index, byte) in payload.enumerated() {
            data.append(byte ^ mask[index % 4])
        }
        return data
    }

    private mutating func nextFrame() throws -> (UInt8, Bool, Data)? {
        let start = incoming.startIndex
        guard incoming.count >= 2 else { return nil }
        let flags = incoming[start]
        let length = incoming[start + 1]
        guard flags & 0x70 == 0, length & 0x80 == 0 else { throw InvalidFrame.invalid }

        let opcode = flags & 0x0F
        let final = flags & 0x80 != 0
        let extra = length == 126 ? 2 : length == 127 ? 8 : 0
        let header = start + 2 + extra
        guard incoming.endIndex >= header else { return nil }
        let size = extra == 0 ? UInt64(length) : incoming[(start + 2)..<header].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
        guard size <= Self.maximumSize, opcode < 8 || (final && size <= 125) else {
            throw InvalidFrame.invalid
        }
        let end = header + Int(size)
        guard incoming.endIndex >= end else { return nil }
        let payload = Data(incoming[header..<end])
        incoming.removeSubrange(..<end)
        return (opcode, final, payload)
    }
}
