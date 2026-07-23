//
//  LSPMessageStreamParser.swift
//  Pine
//
//  Deterministic streaming parser for LSP Content-Length framing.
//

import Foundation

/// A malformed stream condition that was consumed without emitting a message.
nonisolated enum LSPStreamParserError: Error, Equatable, Sendable {
    case headerTooLarge(byteCount: Int)
    case invalidHeader
    case payloadTooLarge(byteCount: Int)
    case invalidJSON
    case incompleteMessage(bufferedBytes: Int)
    case inputAfterEOF

    /// Framing errors make the following byte boundary unknowable. Continuing
    /// could interpret bytes inside a malformed payload as a new LSP message.
    var terminatesStream: Bool {
        switch self {
        case .headerTooLarge, .invalidHeader, .payloadTooLarge, .invalidJSON:
            return true
        case .incompleteMessage, .inputAfterEOF:
            return false
        }
    }
}

/// One parser outcome. Malformed frames are explicit so callers can log them
/// while continuing to drain later valid frames from the same read.
nonisolated enum LSPStreamParserEvent {
    case message([String: Any])
    case malformed(LSPStreamParserError)
}

/// Incrementally parses LSP messages from arbitrarily fragmented byte chunks.
///
/// The parser owns no process or queue. `LSPTransport` confines one instance
/// to its serial I/O queue, while tests can feed it synchronously.
nonisolated struct LSPMessageStreamParser {
    static let defaultMaximumHeaderSize = 64 * 1024
    static let defaultMaximumPayloadSize = 16 * 1024 * 1024

    private static let headerSeparator = Data("\r\n\r\n".utf8)

    private let maximumHeaderSize: Int
    private let maximumPayloadSize: Int
    private var buffer = Data()
    private(set) var isFinished = false

    init(
        maximumHeaderSize: Int = defaultMaximumHeaderSize,
        maximumPayloadSize: Int = defaultMaximumPayloadSize
    ) {
        self.maximumHeaderSize = max(1, maximumHeaderSize)
        self.maximumPayloadSize = max(1, maximumPayloadSize)
    }

    var bufferedByteCount: Int {
        buffer.count
    }

    /// Appends one stdout chunk and drains every complete frame in order.
    mutating func append(_ chunk: Data) -> [LSPStreamParserEvent] {
        guard !isFinished else {
            return chunk.isEmpty ? [] : [.malformed(.inputAfterEOF)]
        }
        guard !chunk.isEmpty else { return [] }

        buffer.append(chunk)
        return drain()
    }

    /// Marks the byte stream as complete.
    ///
    /// A partial header or body is reported once and discarded. Calling
    /// `finish()` repeatedly is idempotent.
    mutating func finish() -> [LSPStreamParserEvent] {
        guard !isFinished else { return [] }
        isFinished = true
        guard !buffer.isEmpty else { return [] }

        let bufferedBytes = buffer.count
        buffer.removeAll(keepingCapacity: false)
        return [.malformed(.incompleteMessage(bufferedBytes: bufferedBytes))]
    }

    private mutating func drain() -> [LSPStreamParserEvent] {
        var events: [LSPStreamParserEvent] = []

        while !buffer.isEmpty {
            guard let separatorRange = buffer.range(
                of: Self.headerSeparator
            ) else {
                if buffer.count > maximumHeaderSize {
                    let byteCount = buffer.count
                    terminateStream(
                        with: .headerTooLarge(byteCount: byteCount),
                        events: &events
                    )
                }
                break
            }

            let headerByteCount = buffer.distance(
                from: buffer.startIndex,
                to: separatorRange.upperBound
            )
            let headerData = buffer.subdata(
                in: buffer.startIndex..<separatorRange.lowerBound
            )
            guard headerData.count <= maximumHeaderSize else {
                terminateStream(
                    with: .headerTooLarge(byteCount: headerData.count),
                    events: &events
                )
                break
            }

            guard let header = String(data: headerData, encoding: .ascii),
                  let payloadLength = LSPMessageFraming.contentLength(
                      from: header
                  ) else {
                terminateStream(with: .invalidHeader, events: &events)
                break
            }

            guard payloadLength <= maximumPayloadSize else {
                terminateStream(
                    with: .payloadTooLarge(byteCount: payloadLength),
                    events: &events
                )
                break
            }

            let completeFrameSize = headerByteCount + payloadLength
            guard buffer.count >= completeFrameSize else {
                break
            }

            let bodyStart = buffer.index(
                buffer.startIndex,
                offsetBy: headerByteCount
            )
            let bodyEnd = buffer.index(
                bodyStart,
                offsetBy: payloadLength
            )
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            consume(completeFrameSize)

            do {
                let object = try JSONSerialization.jsonObject(with: body)
                guard let message = object as? [String: Any] else {
                    terminateStream(with: .invalidJSON, events: &events)
                    break
                }
                events.append(.message(message))
            } catch {
                terminateStream(with: .invalidJSON, events: &events)
                break
            }
        }

        return events
    }

    private mutating func consume(_ byteCount: Int) {
        buffer.removeFirst(byteCount)
    }

    private mutating func terminateStream(
        with error: LSPStreamParserError,
        events: inout [LSPStreamParserEvent]
    ) {
        isFinished = true
        buffer.removeAll(keepingCapacity: false)
        events.append(.malformed(error))
    }
}
