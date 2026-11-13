import Darwin
import Foundation
import Testing
@testable import Pine

@Suite("Literal subprocess argument arrays", .serialized)
nonisolated struct UserTaskSubprocessArgumentsTests {
    private func output(arguments: [String]) throws -> (String, Int32) {
        let process = try UserTaskSubprocess(
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"), arguments: arguments,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        process.standardInput.closeFile()
        let data = process.standardOutput.readDataToEndOfFile()
        process.standardOutput.closeFile()
        process.standardError.closeFile()
        let exit = process.waitForExit()
        return (String(bytes: data, encoding: .utf8) ?? "", exit)
    }

    @Test func shellMetacharactersRemainLiteral() throws {
        let literal = "$(printf changed); echo more | cat > redirected"
        let result = try output(arguments: ["%s", literal])
        #expect(result.0 == literal)
        #expect(result.1 == 0)
    }

    @Test func emptyUnicodeWhitespaceAndQuoteArgumentsStaySeparate() throws {
        let result = try output(arguments: ["[%s]", "", "a b", "雪", "'\"", "--"])
        #expect(result.0 == "[][a b][雪]['\"][--]")
        #expect(result.1 == 0)
    }

    @Test func invalidArgumentArraysAreRejectedBeforeSpawn() {
        for arguments in [
            ["safe\0unsafe"],
            Array(repeating: "x", count: 257),
            [String(repeating: "x", count: 65_537)],
        ] {
            #expect(throws: (any Error).self) {
                try UserTaskSubprocess(
                    executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                    arguments: arguments, workingDirectory: nil
                )
            }
        }
    }

    @Test func legacyShellEntryPointRetainsShellBehavior() throws {
        let process = try UserTaskSubprocess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            command: "printf '%s' legacy-shell", workingDirectory: nil
        )
        process.standardInput.closeFile()
        let data = process.standardOutput.readDataToEndOfFile()
        process.standardOutput.closeFile()
        process.standardError.closeFile()
        #expect(String(bytes: data, encoding: .utf8) == "legacy-shell")
        #expect(process.waitForExit() == 0)
    }

    @Test func argumentProcessKeepsDedicatedGroupAndDirectChildReaping() throws {
        let process = try UserTaskSubprocess(
            executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        process.standardInput.closeFile()
        let pid = process.processGroup.identifier
        #expect(getpgid(pid) == pid)
        process.processGroup.requestTermination()
        let exit = process.waitForExit()
        #expect(exit == SIGTERM || exit == SIGKILL)
        #expect(process.processGroup.waitForRequestedTermination())
        process.standardOutput.closeFile()
        process.standardError.closeFile()
        var status: Int32 = 0
        errno = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }
}
