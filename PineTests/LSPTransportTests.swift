//
//  LSPTransportTests.swift
//  PineTests
//
//  Deterministic coverage for LSP framing, streaming, and process lifecycle.
//

import Darwin
import Foundation
import Testing
@testable import Pine

@Suite("LSP Message Framing Tests")
struct LSPMessageFramingTests {
    @Test("Frame uses UTF-8 byte length for ASCII and multibyte JSON")
    func frameUsesUTF8ByteLength() throws {
        for text in ["plain ASCII", "Привет, Pine 🌲"] {
            let frame = LSPMessageFraming.frame([
                "jsonrpc": "2.0",
                "id": 1,
                "text": text
            ])
            let parts = try splitFrame(frame)

            #expect(
                LSPMessageFraming.contentLength(from: parts.header)
                    == parts.body.count
            )
            let object = try JSONSerialization.jsonObject(with: parts.body)
            let message = try #require(object as? [String: Any])
            #expect(message["text"] as? String == text)
        }
    }

    @Test("Content-Length accepts casing and surrounding whitespace")
    func contentLengthAcceptsCasingAndWhitespace() {
        let header = [
            "Content-Type: application/vscode-jsonrpc; charset=utf-8",
            "  cOnTeNt-LeNgTh \t: \t42  "
        ].joined(separator: "\r\n")

        #expect(LSPMessageFraming.contentLength(from: header) == 42)
    }

    @Test("Content-Length rejects ambiguous and malformed values")
    func contentLengthRejectsMalformedValues() {
        #expect(
            LSPMessageFraming.contentLength(
                from: "X-Content-Length: 12"
            ) == nil
        )
        #expect(
            LSPMessageFraming.contentLength(
                from: "Content-Length: 12junk"
            ) == nil
        )
        #expect(
            LSPMessageFraming.contentLength(
                from: "Content-Length: -1"
            ) == nil
        )
        #expect(
            LSPMessageFraming.contentLength(
                from: "Content-Length:"
            ) == nil
        )
        #expect(
            LSPMessageFraming.contentLength(
                from: "Content-Length: 1\r\ncontent-length: 1"
            ) == nil
        )
        #expect(
            LSPMessageFraming.contentLength(
                from: "Content-Length: \(String(repeating: "9", count: 100))"
            ) == nil
        )
        #expect(
            LSPMessageFraming.contentLength(
                from: "Content-Type: application/json"
            ) == nil
        )
    }

    private func splitFrame(
        _ frame: Data
    ) throws -> (header: String, body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let range = try #require(frame.range(of: separator))
        let headerData = frame.subdata(
            in: frame.startIndex..<range.lowerBound
        )
        let header = try #require(
            String(data: headerData, encoding: .ascii)
        )
        let body = frame.subdata(in: range.upperBound..<frame.endIndex)
        return (header, body)
    }
}

@Suite("LSP Message Stream Parser Tests")
struct LSPMessageStreamParserTests {
    @Test("Every header and body split boundary produces one message")
    func parsesEverySplitBoundary() {
        let frame = makeFrame(id: 1, text: "Привет 🌲")

        for splitIndex in 0...frame.count {
            var parser = LSPMessageStreamParser()
            var events = parser.append(
                Data(frame.prefix(splitIndex))
            )
            events += parser.append(
                Data(frame.dropFirst(splitIndex))
            )

            #expect(
                messageIDs(in: events) == [1],
                "split index \(splitIndex)"
            )
            #expect(
                parserErrors(in: events).isEmpty,
                "split index \(splitIndex)"
            )
            #expect(parser.bufferedByteCount == 0)
        }
    }

    @Test("Byte-by-byte UTF-8 input stays ordered")
    func parsesByteByByte() {
        let first = makeFrame(id: 1, text: "один")
        let second = makeFrame(id: 2, text: "два")
        var stream = first
        stream.append(second)

        var parser = LSPMessageStreamParser()
        var events: [LSPStreamParserEvent] = []
        for byte in stream {
            events += parser.append(Data([byte]))
        }

        #expect(messageIDs(in: events) == [1, 2])
        #expect(parserErrors(in: events).isEmpty)
    }

    @Test("Multiple coalesced frames are emitted in wire order")
    func parsesCoalescedFrames() {
        var stream = makeFrame(id: 1)
        stream.append(makeFrame(id: 2))
        stream.append(makeFrame(id: 3))

        var parser = LSPMessageStreamParser()
        let events = parser.append(stream)

        #expect(messageIDs(in: events) == [1, 2, 3])
        #expect(parserErrors(in: events).isEmpty)
        #expect(parser.bufferedByteCount == 0)
    }

    @Test("A complete frame precedes one explicit incomplete EOF error")
    func reportsIncompleteTrailingFrameAtEOF() {
        let first = makeFrame(id: 1)
        let partial = Data(makeFrame(id: 2).dropLast(3))
        var stream = first
        stream.append(partial)

        var parser = LSPMessageStreamParser()
        var events = parser.append(stream)
        #expect(messageIDs(in: events) == [1])
        #expect(parser.bufferedByteCount == partial.count)

        events += parser.finish()
        #expect(
            parserErrors(in: events) == [
                .incompleteMessage(bufferedBytes: partial.count)
            ]
        )
        #expect(parser.bufferedByteCount == 0)
        #expect(parser.finish().isEmpty)
    }

    @Test("Malformed header terminates before a coalesced apparent frame")
    func malformedHeaderTerminatesStream() {
        var stream = Data("Content-Length: 12junk\r\n\r\n".utf8)
        stream.append(makeFrame(id: 7))

        var parser = LSPMessageStreamParser()
        let events = parser.append(stream)

        #expect(parserErrors(in: events) == [.invalidHeader])
        #expect(messageIDs(in: events).isEmpty)
        #expect(parser.isFinished)
        #expect(parser.bufferedByteCount == 0)
        #expect(
            parser.append(makeFrame(id: 8)).errors == [.inputAfterEOF]
        )
    }

    @Test("Messages before malformed framing remain ordered")
    func emitsCompletedMessagesBeforeTerminating() {
        var stream = makeFrame(id: 1)
        stream.append(Data("Content-Length: nope\r\n\r\n".utf8))
        stream.append(makeFrame(id: 2))

        var parser = LSPMessageStreamParser()
        let events = parser.append(stream)

        #expect(messageIDs(in: events) == [1])
        #expect(parserErrors(in: events) == [.invalidHeader])
        #expect(parser.isFinished)
    }

    @Test("Non-ASCII header terminates before a coalesced apparent frame")
    func nonASCIIHeaderTerminatesStream() {
        var stream = Data([0xFF])
        stream.append(Data("\r\n\r\n".utf8))
        stream.append(makeFrame(id: 8))

        var parser = LSPMessageStreamParser()
        let events = parser.append(stream)

        #expect(parserErrors(in: events) == [.invalidHeader])
        #expect(messageIDs(in: events).isEmpty)
        #expect(parser.isFinished)
    }

    @Test("Invalid JSON terminates before a coalesced apparent frame")
    func invalidJSONTerminatesStream() {
        var stream = frame(body: Data("{invalid".utf8))
        stream.append(makeFrame(id: 9))

        var parser = LSPMessageStreamParser()
        let events = parser.append(stream)

        #expect(parserErrors(in: events) == [.invalidJSON])
        #expect(messageIDs(in: events).isEmpty)
        #expect(parser.isFinished)
    }

    @Test("A non-object JSON payload is malformed")
    func rejectsNonObjectJSON() {
        var parser = LSPMessageStreamParser()
        let events = parser.append(frame(body: Data("[1, 2, 3]".utf8)))

        #expect(messageIDs(in: events).isEmpty)
        #expect(parserErrors(in: events) == [.invalidJSON])
        #expect(parser.isFinished)
    }

    @Test("Missing separator remains buffered until EOF")
    func reportsHeaderWithoutSeparatorAtEOF() {
        let header = Data("Content-Length: 10\r\n".utf8)
        var parser = LSPMessageStreamParser()

        #expect(parser.append(header).isEmpty)
        #expect(
            parser.finish().errors == [
                .incompleteMessage(bufferedBytes: header.count)
            ]
        )
    }

    @Test("Header and payload limits fail predictably")
    func enforcesSizeLimits() {
        var headerParser = LSPMessageStreamParser(
            maximumHeaderSize: 8
        )
        #expect(
            headerParser.append(Data(repeating: 65, count: 9)).errors
                == [.headerTooLarge(byteCount: 9)]
        )
        #expect(headerParser.isFinished)

        var payloadParser = LSPMessageStreamParser(
            maximumPayloadSize: 4
        )
        let oversizedHeader = Data("Content-Length: 5\r\n\r\n".utf8)
        #expect(
            payloadParser.append(oversizedHeader).errors
                == [.payloadTooLarge(byteCount: 5)]
        )
        #expect(payloadParser.isFinished)
        #expect(
            payloadParser.append(makeFrame(id: 1)).errors
                == [.inputAfterEOF]
        )
    }

    @Test("EOF is idempotent and later input is rejected")
    func finishIsIdempotent() {
        var parser = LSPMessageStreamParser()

        #expect(parser.finish().isEmpty)
        #expect(parser.finish().isEmpty)
        #expect(
            parser.append(makeFrame(id: 1)).errors
                == [.inputAfterEOF]
        )
        #expect(parser.bufferedByteCount == 0)
    }

}

@Suite("LSP Process Transport Tests", .serialized)
@MainActor
struct LSPProcessTransportTests {
    @Test("Stdout descriptor setup succeeds or fails closed")
    func configuresNonblockingDescriptor() {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForReading.fileDescriptor

        #expect(
            LSPTransport.configureNonBlocking(descriptor: descriptor)
        )
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        #expect(flags != -1)
        #expect(flags & O_NONBLOCK != 0)
        #expect(!LSPTransport.configureNonBlocking(descriptor: -1))
    }

    @Test(
        "Configured stderr captures child diagnostics",
        .timeLimit(.minutes(1))
    )
    func capturesStandardError() async throws {
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineLSPStderr-\(UUID().uuidString)"
            )
        #expect(
            FileManager.default.createFile(
                atPath: captureURL.path,
                contents: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: captureURL) }

        let captureHandle = try FileHandle(forWritingTo: captureURL)
        defer { try? captureHandle.close() }
        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        defer { transport.terminate(timeout: 0.1) }

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'sourcekit failure' >&2"
                ],
                environment: [:],
                standardError: captureHandle
            )
        )
        #expect(
            await waitUntil {
                recorder.terminations.count == 1
            }
        )
        try captureHandle.synchronize()

        let capturedData = try Data(contentsOf: captureURL)
        #expect(
            String(data: capturedData, encoding: .utf8)
                == "sourcekit failure"
        )
    }

    @Test(
        "Configured working directory is applied to the child",
        .timeLimit(.minutes(1))
    )
    func usesConfiguredWorkingDirectory() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineLSPWorkingDirectory-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let captureURL = directoryURL.appendingPathComponent("stderr")
        #expect(
            FileManager.default.createFile(
                atPath: captureURL.path,
                contents: nil
            )
        )
        let captureHandle = try FileHandle(forWritingTo: captureURL)
        defer { try? captureHandle.close() }

        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        defer { transport.terminate(timeout: 0.1) }

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s\\n%s' \"$PWD\" \"$PATH\" >&2"
                ],
                environment: ["PATH": "/isolated/bin"],
                currentDirectoryURL: directoryURL,
                standardError: captureHandle
            )
        )
        #expect(
            await waitUntil {
                recorder.terminations.count == 1
            }
        )
        try captureHandle.synchronize()

        let capturedData = try Data(contentsOf: captureURL)
        let capturedOutput = try #require(
            String(data: capturedData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let capturedLines = capturedOutput.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        try #require(capturedLines.count == 2)
        #expect(
            canonicalDarwinPath(capturedLines[0])
                == canonicalDarwinPath(directoryURL.path)
        )
        #expect(capturedLines[1] == "/isolated/bin")
    }

    @Test(
        "Echo process preserves callback order and terminates once",
        .timeLimit(.minutes(1))
    )
    func echoProcessPreservesOrder() async {
        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        defer { transport.terminate(timeout: 0.1) }

        #expect(
            transport.start(
                command: "/bin/cat",
                arguments: [],
                environment: [:]
            )
        )
        transport.send(["jsonrpc": "2.0", "id": 1])
        transport.send(["jsonrpc": "2.0", "id": 2])
        transport.send(["jsonrpc": "2.0", "id": 3])

        #expect(
            await waitUntil {
                recorder.messages.count == 3
            }
        )
        #expect(
            recorder.messages.compactMap { $0["id"] as? Int }
                == [1, 2, 3]
        )

        transport.terminate(timeout: 1)
        #expect(
            await waitUntil {
                recorder.terminations.count == 1
            }
        )
        #expect(recorder.terminations == [.requested])
        #expect(!transport.isRunning)
    }

    @Test(
        "Natural process exit reports termination exactly once",
        .timeLimit(.minutes(1))
    )
    func naturalProcessExitIsReportedOnce() async {
        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder

        #expect(
            transport.start(
                command: "/usr/bin/true",
                arguments: [],
                environment: [:]
            )
        )
        #expect(
            await waitUntil {
                recorder.terminations.count == 1
            }
        )

        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.terminations.count == 1)
        #expect(!transport.isRunning)
        switch recorder.terminations.first {
        case .endOfFile, .processExited(status: 0):
            break
        default:
            Issue.record("Unexpected natural-exit reason")
        }
    }

    @Test(
        "Final framed response is delivered before immediate process exit",
        .timeLimit(.minutes(1))
    )
    func finalResponsePrecedesTermination() async throws {
        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        let frame = try #require(
            String(bytes: makeFrame(id: 41), encoding: .utf8)
        )

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s' \"$FRAME\""
                ],
                environment: ["FRAME": frame]
            )
        )
        #expect(
            await waitUntil {
                recorder.terminations.count == 1
            }
        )

        #expect(
            recorder.messages.compactMap { $0["id"] as? Int } == [41]
        )
        #expect(recorder.callbackOrder == ["message", "termination"])
        #expect(!transport.isRunning)
    }

    @Test(
        "EOF stops a child that remains alive with stdout closed",
        .timeLimit(.minutes(1))
    )
    func endOfFileStopsLiveProcess() async throws {
        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        defer { transport.terminate(timeout: 0) }

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; exec 1>&-; exec /bin/sleep 30"
                ],
                environment: [:]
            )
        )
        let processID = try #require(transport.processIdentifier)
        #expect(
            await waitUntil {
                recorder.terminations == [.endOfFile]
            }
        )
        #expect(
            await waitUntil {
                !isProcessAlive(processID)
            }
        )
        #expect(!transport.isRunning)
        #expect(recorder.terminations.count == 1)
    }

    @Test(
        "EOF cleanup survives shared utility-queue starvation",
        .timeLimit(.minutes(1))
    )
    func endOfFileCleanupSurvivesUtilityStarvation() async throws {
        let saturation = UtilityQueueSaturation()
        defer { saturation.release() }
        await saturation.waitUntilSaturated()

        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        defer { transport.terminate(timeout: 0) }

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; exec 1>&-; exec /bin/sleep 30"
                ],
                environment: [:]
            )
        )
        let processID = try #require(transport.processIdentifier)
        #expect(
            await waitUntil {
                recorder.terminations == [.endOfFile]
            }
        )
        #expect(
            await waitUntil {
                !isProcessAlive(processID)
            }
        )
        #expect(!transport.isRunning)
        #expect(recorder.terminations.count == 1)
    }

    @Test(
        "Pending request fails when transport terminates",
        .timeLimit(.minutes(1))
    )
    func pendingRequestFailsOnTermination() async {
        let client = LSPClient(language: "test")
        let request = Task { @MainActor in
            do {
                _ = try await client.sendRequest(
                    "test/request",
                    params: [:]
                )
                return false
            } catch let error as LSPTransportError {
                return error.termination
                    == .processExited(status: 17)
            } catch {
                return false
            }
        }

        #expect(
            await waitUntil {
                client.pendingRequestCount == 1
            }
        )
        client.transportDidTerminate(.processExited(status: 17))

        #expect(await request.value)
        #expect(client.pendingRequestCount == 0)
    }

    @Test(
        "Requests preserve array and null JSON results",
        .timeLimit(.minutes(1))
    )
    func requestPreservesPolymorphicResults() async throws {
        let client = LSPClient(language: "test")
        let location: [String: Any] = [
            "uri": "file:///tmp/Pine.swift",
            "range": [
                "start": ["line": 1, "character": 2],
                "end": ["line": 1, "character": 6]
            ]
        ]

        let arrayRequest = Task { @MainActor in
            let result = try await client.sendRequest(
                "textDocument/definition",
                params: [:],
                timeout: .seconds(2)
            )
            return SendableJSONValueBox(result)
        }
        try #require(
            await waitUntil {
                client.pendingRequestCount == 1
            }
        )
        client.transport(didReceive: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [location]
        ])

        let arrayResult = try #require(
            try await arrayRequest.value.value as? [Any]
        )
        let decodedLocation = try #require(
            arrayResult.first as? [String: Any]
        )
        #expect(decodedLocation["uri"] as? String == location["uri"] as? String)
        #expect(client.pendingRequestCount == 0)

        let nullRequest = Task { @MainActor in
            let result = try await client.sendRequest(
                "textDocument/hover",
                params: [:],
                timeout: .seconds(2)
            )
            return SendableJSONValueBox(result)
        }
        try #require(
            await waitUntil {
                client.pendingRequestCount == 1
            }
        )
        client.transport(didReceive: [
            "jsonrpc": "2.0",
            "id": 2,
            "result": NSNull()
        ])

        let nullResult = try await nullRequest.value.value
        #expect(nullResult is NSNull)
        #expect(client.pendingRequestCount == 0)
    }

    @Test(
        "Cancelling a request clears its pending continuation",
        .timeLimit(.minutes(1))
    )
    func requestCancellationClearsPendingState() async throws {
        let client = LSPClient(language: "test")
        let request = Task { @MainActor in
            let result = try await client.sendRequest(
                "textDocument/hover",
                params: [:]
            )
            return SendableJSONValueBox(result)
        }

        try #require(
            await waitUntil {
                client.pendingRequestCount == 1
            }
        )
        request.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await request.value
        }
        #expect(client.pendingRequestCount == 0)
    }

    @Test(
        "Initialize timeout terminates a real child",
        .timeLimit(.minutes(1))
    )
    func initializeTimeoutTerminatesRealChild() async throws {
        let client = LSPClient(language: "test")
        defer { client.shutdown() }

        let clock = ContinuousClock()
        let startedAt = clock.now
        let start = Task { @MainActor in
            await client.start(
                command: "/bin/sleep",
                arguments: ["30"],
                rootURI: nil,
                environment: [:],
                initializationTimeout: .milliseconds(100)
            )
        }

        try #require(
            await waitUntil {
                client.pendingRequestCount == 1
            }
        )
        let processID = try #require(client.transport.processIdentifier)
        #expect(!(await start.value))

        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed < .seconds(2))
        #expect(client.state == .failed)
        #expect(client.pendingRequestCount == 0)
        #expect(!client.transport.isRunning)
        #expect(!isProcessAlive(processID))
    }

    @Test(
        "Initialize timeout cleanup does not block MainActor",
        .timeLimit(.minutes(1))
    )
    func initializeTimeoutCleanupDoesNotBlockMainActor() async throws {
        let client = LSPClient(language: "test")
        defer { client.shutdown() }

        let clock = ContinuousClock()
        let startedAt = clock.now
        var didStartReturn = false
        let start = Task { @MainActor in
            let result = await client.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; exec /bin/sleep 30"
                ],
                rootURI: nil,
                environment: [:],
                initializationTimeout: .milliseconds(250)
            )
            didStartReturn = true
            return result
        }

        try #require(
            await waitUntil {
                client.pendingRequestCount == 1
            }
        )
        let processID = try #require(client.transport.processIdentifier)

        // Allow the shell to install its signal disposition and exec the real
        // sleep process, forcing cleanup through the bounded SIGKILL fallback.
        try await Task.sleep(for: .milliseconds(100))
        let heartbeat = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            return !didStartReturn
        }

        #expect(await heartbeat.value)
        #expect(!(await start.value))

        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed < .seconds(2))
        #expect(client.state == .failed)
        #expect(client.pendingRequestCount == 0)
        #expect(!client.transport.isRunning)
        #expect(!isProcessAlive(processID))
    }

    @Test(
        "Graceful shutdown awaits acknowledgement before exit",
        .timeLimit(.minutes(1))
    )
    func gracefulShutdownUsesProtocolOrder() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineLSPShutdown-\(UUID().uuidString)"
            )
        #expect(
            FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil
            )
        )
        defer { try? FileManager.default.removeItem(at: logURL) }

        let server = """
        read_message() {
            IFS= read -r header || exit 21
            length=$(/usr/bin/printf '%s' "$header" | /usr/bin/tr -cd '0-9')
            IFS= read -r separator || exit 22
            body=$(/bin/dd bs=1 count="$length" 2>/dev/null)
            /usr/bin/printf '%s\\n' "$body" >> "$LOG_PATH"
        }
        write_message() {
            body="$1"
            /usr/bin/printf 'Content-Length: %s\\r\\n\\r\\n%s' \
                "${#body}" "$body"
        }
        read_message
        write_message '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}'
        read_message
        read_message
        write_message '{"jsonrpc":"2.0","id":2,"result":null}'
        read_message
        """

        let client = LSPClient(language: "test")
        defer { client.shutdown() }
        #expect(
            await client.start(
                command: "/bin/sh",
                arguments: ["-c", server],
                rootURI: nil,
                environment: ["LOG_PATH": logURL.path]
            )
        )
        #expect(
            await client.shutdownGracefully(timeout: .seconds(2))
        )
        #expect(client.state == .exited)
        #expect(!client.transport.isRunning)

        let logData = try Data(contentsOf: logURL)
        let log = try #require(
            String(data: logData, encoding: .utf8)
        )
        let messages = log.split(separator: "\n").map(String.init)
        try #require(messages.count == 4)
        #expect(messages[0].contains("\"method\":\"initialize\""))
        #expect(messages[1].contains("\"method\":\"initialized\""))
        #expect(messages[2].contains("\"method\":\"shutdown\""))
        #expect(messages[3].contains("\"method\":\"exit\""))
    }

    @Test(
        "Graceful shutdown rejects a nonzero server exit",
        .timeLimit(.minutes(1))
    )
    func gracefulShutdownRejectsCrashExit() async {
        let server = """
        read_message() {
            IFS= read -r header || exit 21
            length=$(/usr/bin/printf '%s' "$header" | /usr/bin/tr -cd '0-9')
            IFS= read -r separator || exit 22
            /bin/dd bs=1 count="$length" of=/dev/null 2>/dev/null
        }
        write_message() {
            body="$1"
            /usr/bin/printf 'Content-Length: %s\\r\\n\\r\\n%s' \
                "${#body}" "$body"
        }
        read_message
        write_message '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}'
        read_message
        read_message
        write_message '{"jsonrpc":"2.0","id":2,"result":null}'
        read_message
        exit 7
        """

        let client = LSPClient(language: "test")
        defer { client.shutdown() }
        #expect(
            await client.start(
                command: "/bin/sh",
                arguments: ["-c", server],
                rootURI: nil,
                environment: [:]
            )
        )

        #expect(
            !(await client.shutdownGracefully(timeout: .seconds(2)))
        )
        #expect(client.state == .exited)
        #expect(!client.transport.isRunning)
    }

    @Test("Graceful shutdown requires an initialized server")
    func gracefulShutdownRequiresInitializedServer() async {
        let client = LSPClient(language: "test")

        #expect(
            !(await client.shutdownGracefully(
                timeout: .milliseconds(50)
            ))
        )
        #expect(client.state == .exited)
    }

    @Test(
        "Graceful shutdown timeout force-terminates the child",
        .timeLimit(.minutes(1))
    )
    func gracefulShutdownTimeoutIsBounded() async {
        let server = """
        IFS= read -r header || exit 21
        length=$(/usr/bin/printf '%s' "$header" | /usr/bin/tr -cd '0-9')
        IFS= read -r separator || exit 22
        /bin/dd bs=1 count="$length" of=/dev/null 2>/dev/null
        body='{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}'
        /usr/bin/printf 'Content-Length: %s\\r\\n\\r\\n%s' \
            "${#body}" "$body"
        exec /bin/sleep 30
        """
        let client = LSPClient(language: "test")
        defer { client.shutdown() }
        #expect(
            await client.start(
                command: "/bin/sh",
                arguments: ["-c", server],
                rootURI: nil,
                environment: [:]
            )
        )
        let processID = client.transport.processIdentifier

        let clock = ContinuousClock()
        let startedAt = clock.now
        let didShutDownGracefully = await client.shutdownGracefully(
            timeout: .milliseconds(100)
        )
        #expect(!didShutDownGracefully)
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .seconds(2))
        #expect(client.state == .exited)
        #expect(!client.transport.isRunning)
        #expect(client.pendingRequestCount == 0)
        if let processID {
            #expect(!isProcessAlive(processID))
        }
    }

    @Test(
        "Termination timeout kills an unresponsive child",
        .timeLimit(.minutes(1))
    )
    func terminationTimeoutIsBounded() async {
        let transport = LSPTransport()
        defer { transport.terminate(timeout: 0) }

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; exec /bin/sleep 30"
                ],
                environment: [:]
            )
        )
        let processID = transport.processIdentifier
        try? await Task.sleep(for: .milliseconds(100))

        let clock = ContinuousClock()
        let startedAt = clock.now
        transport.terminate(timeout: 0.1)
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .seconds(2))
        #expect(!transport.isRunning)
        if let processID {
            #expect(!isProcessAlive(processID))
        }
    }

    @Test(
        "Async termination survives shared utility-queue starvation",
        .timeLimit(.minutes(1))
    )
    func asyncTerminationSurvivesUtilityStarvation() async throws {
        let transport = LSPTransport()
        defer { transport.terminate(timeout: 0) }
        #expect(
            transport.start(
                command: "/bin/sleep",
                arguments: ["30"],
                environment: [:]
            )
        )
        let processID = try #require(transport.processIdentifier)

        let saturation = UtilityQueueSaturation()
        defer { saturation.release() }
        await saturation.waitUntilSaturated()
        // Keeps the pre-fix implementation from hanging indefinitely while
        // its terminate block waits behind the saturated utility queue.
        saturation.release(after: 2.25)

        let clock = ContinuousClock()
        let startedAt = clock.now
        await transport.terminateAsync(timeout: 0.1)
        let elapsed = startedAt.duration(to: clock.now)

        #expect(elapsed < .seconds(2))
        #expect(!transport.isRunning)
        #expect(!isProcessAlive(processID))
    }

    @Test(
        "Malformed framing terminates the stream and child process",
        .timeLimit(.minutes(1))
    )
    func malformedFramingStopsTransport() async {
        let transport = LSPTransport()
        let recorder = RecordingLSPTransportDelegate()
        transport.delegate = recorder
        defer { transport.terminate(timeout: 0) }

        #expect(
            transport.start(
                command: "/bin/sh",
                arguments: [
                    "-c",
                    """
                    trap '' TERM
                    printf 'Content-Length: nope\\r\\n\\r\\n'
                    exec /bin/sleep 30
                    """
                ],
                environment: [:]
            )
        )
        #expect(
            await waitUntil {
                recorder.terminations
                    == [.protocolViolation(.invalidHeader)]
            }
        )
        #expect(recorder.messages.isEmpty)
        #expect(
            await waitUntil {
                !transport.isRunning
            }
        )
        #expect(recorder.terminations.count == 1)
    }

    @Test("Invalid executable fails without creating a running transport")
    func invalidExecutableFailsToStart() {
        let transport = LSPTransport()

        #expect(
            !transport.start(
                command: "/definitely/missing/pine-lsp",
                arguments: [],
                environment: [:]
            )
        )
        #expect(!transport.isRunning)
    }
}

@MainActor
private final class RecordingLSPTransportDelegate: LSPTransportDelegate {
    var messages: [[String: Any]] = []
    var terminations: [LSPTransportTermination] = []
    var callbackOrder: [String] = []

    func transport(didReceive message: [String: Any]) {
        messages.append(message)
        callbackOrder.append("message")
    }

    func transportDidTerminate(_ reason: LSPTransportTermination) {
        terminations.append(reason)
        callbackOrder.append("termination")
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private func isProcessAlive(_ processID: pid_t) -> Bool {
    if Darwin.kill(processID, 0) == 0 {
        return true
    }
    return errno != ESRCH
}

nonisolated private final class UtilityQueueSaturation:
    @unchecked Sendable {
    private static let releaseQueue = DispatchQueue(
        label: "com.pine.tests.utility-saturation-release",
        qos: .userInitiated
    )

    private let blockerCount: Int
    private let gate = DispatchSemaphore(value: 0)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var isReleased = false

    init(blockerCount: Int = 256) {
        self.blockerCount = blockerCount
        for _ in 0..<blockerCount {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [gate, group] in
                gate.wait()
                group.leave()
            }
        }
    }

    func waitUntilSaturated() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    func release(after delay: TimeInterval) {
        Self.releaseQueue.asyncAfter(deadline: .now() + delay) { [self] in
            release()
        }
    }

    func release() {
        let shouldRelease = lock.withLock {
            guard !isReleased else { return false }
            isReleased = true
            return true
        }
        guard shouldRelease else { return }
        for _ in 0..<blockerCount {
            gate.signal()
        }
        group.wait()
    }

    deinit {
        release()
    }
}

private func canonicalDarwinPath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    if standardized.hasPrefix("/private/") {
        return String(standardized.dropFirst("/private".count))
    }
    return standardized
}

private func makeFrame(id: Int, text: String = "") -> Data {
    var payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id
    ]
    if !text.isEmpty {
        payload["text"] = text
    }
    return LSPMessageFraming.frame(payload)
}

private func frame(body: Data) -> Data {
    var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    framed.append(body)
    return framed
}

private func messageIDs(
    in events: [LSPStreamParserEvent]
) -> [Int] {
    events.compactMap { event in
        guard case .message(let message) = event else { return nil }
        return message["id"] as? Int
    }
}

private func parserErrors(
    in events: [LSPStreamParserEvent]
) -> [LSPStreamParserError] {
    events.compactMap { event in
        guard case .malformed(let error) = event else { return nil }
        return error
    }
}

private extension Array where Element == LSPStreamParserEvent {
    var errors: [LSPStreamParserError] {
        parserErrors(in: self)
    }
}
