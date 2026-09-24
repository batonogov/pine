//
//  BoundedProcessExitTests.swift
//  PineTests
//
//  Tests for the shared bounded child-process wait (issue #1622).
//

import Foundation
import Testing

@Suite("BoundedProcessExit Tests")
struct BoundedProcessExitTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-bounded-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A successful command returns its stdout")
    func successfulCommandReturnsStdout() throws {
        let output = try runShellBounded("printf pine-bounded", at: nil)

        #expect(output == "pine-bounded")
    }

    @Test("The command runs in the requested directory")
    func commandRunsInRequestedDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pwd = try runShellBounded("pwd", at: dir)

        #expect(pwd.contains(dir.lastPathComponent))
    }

    @Test("A non-zero exit throws ShellError carrying the command and stderr")
    func nonZeroExitThrowsShellError() {
        do {
            _ = try runShellBounded("echo boom >&2; exit 3", at: nil)
            Issue.record("'exit 3' must throw instead of returning")
        } catch let error as NSError {
            #expect(error.domain == "ShellError")
            #expect(error.code == 3)
            #expect(
                error.localizedDescription.contains("boom"),
                "The child's stderr must land in the failure message"
            )
            #expect(
                error.localizedDescription.contains("exit 3"),
                "The failed command must be named in the message"
            )
        }
    }

    @Test("A hung command throws within the deadline instead of blocking forever")
    func hungCommandThrowsBounded() throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try runShellBounded("sleep 60", at: nil, deadline: 1)
            Issue.record("'sleep 60' must throw a timeout instead of hanging")
        } catch let error as BoundedProcessExitError {
            #expect(
                String(describing: error).contains("sleep 60"),
                "The timeout error must name the hung command"
            )
        }

        // This is a boundedness invariant, not a performance measurement:
        // the point is "seconds, not forever".
        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed < .seconds(10))
    }

    @Test("A child that ignores SIGTERM is killed after the grace period")
    func sigtermIgnoringChildIsKilled() throws {
        // `trap '' TERM` makes sh ignore SIGTERM; only SIGKILL ends it.
        // This test drives runProcessBounded with its own Process so it can
        // assert the child's fate directly: with the SIGKILL escalation
        // removed from the helper, the process would still be running here
        // and the test would go red.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 60"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            _ = try runProcessBounded(
                process,
                commandDescription: "trap '' TERM; sleep 60",
                deadline: 1,
                gracePeriod: 1,
                postExitAllowance: 1
            )
            Issue.record("A SIGTERM-immune child must still time out")
        } catch is BoundedProcessExitError {
            // Expected: the deadline fired.
        }

        #expect(
            !process.isRunning,
            "SIGKILL escalation must actually end the child"
        )
        // Boundedness invariant, not a performance measurement.
        #expect(startedAt.duration(to: clock.now) < .seconds(10))
    }

    @Test("A grandchild holding the pipe does not hang output collection")
    func grandchildHoldingPipeDoesNotHangCollection() throws {
        // `sh` prints and exits, but the backgrounded `sleep` inherits the
        // pipe's write end and withholds EOF — without the bounded collect
        // this call would hang forever on readDataToEndOfFile.
        let clock = ContinuousClock()
        let startedAt = clock.now

        let output = try runShellBounded(
            "sleep 60 & echo hi",
            at: nil,
            deadline: 5,
            gracePeriod: 1,
            postExitAllowance: 1
        )

        // The orphaned grandchild keeps the pipe open, so the helper
        // returns the partial data drained before the allowance expired.
        #expect(output.contains("hi"))
        // Boundedness invariant, not a performance measurement.
        #expect(startedAt.duration(to: clock.now) < .seconds(10))
    }

    @Test("Output larger than the pipe buffer is drained without deadlocking")
    func largeOutputIsDrained() throws {
        // 200 KB of 'x' — well past the 64 KB pipe buffer. Without the
        // background drain the child blocks on write(2) and the deadline
        // fires as a false timeout.
        let output = try runShellBounded(
            "head -c 200000 /dev/zero | tr '\\0' x",
            at: nil
        )

        #expect(output.count == 200_000)
        #expect(output.allSatisfy { $0 == "x" })
    }

    @Test("A process with merged output pipes reports the same data in both fields")
    func mergedPipesReportBothStreams() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo out; echo err >&2"]
        let merged = Pipe()
        process.standardOutput = merged
        process.standardError = merged

        let output = try runProcessBounded(
            process,
            commandDescription: "merged echo"
        )

        #expect(output.terminationStatus == 0)
        let text = String(data: output.standardOutput, encoding: .utf8) ?? ""
        #expect(
            text.contains("out") && text.contains("err"),
            "Both streams must be visible through the shared pipe"
        )
    }

    @Test("runProcessBounded reports a non-zero status without throwing")
    func nonZeroStatusIsReportedNotThrown() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = try runProcessBounded(
            process,
            commandDescription: "/usr/bin/false"
        )

        #expect(output.terminationStatus != 0)
    }
}
