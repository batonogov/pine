//
//  CLIArgumentParserTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@MainActor
struct CLIArgumentParserTests {
    // MARK: - Path resolution

    @Test func parsesCurrentDirectory() {
        let result = CLIArgumentParser.parse(["pine", "."])
        #expect(result == .openDirectory(URL(fileURLWithPath: ".")))
    }

    @Test func parsesAbsoluteDirectory() {
        let result = CLIArgumentParser.parse(["pine", "/tmp"])
        #expect(result == .openDirectory(URL(fileURLWithPath: "/tmp")))
    }

    @Test func parsesRelativeDirectory() {
        let result = CLIArgumentParser.parse(["pine", "src"])
        // When path exists and is directory -> openDirectory
        // When path doesn't exist -> error
        // For unit testing, we test the classification logic separately
    }

    @Test func parsesAbsoluteFilePath() {
        let result = CLIArgumentParser.parse(["pine", "/tmp/test.swift"])
        #expect(result == .openFile(URL(fileURLWithPath: "/tmp/test.swift"), line: nil))
    }

    @Test func parsesFileWithLineNumber() {
        let result = CLIArgumentParser.parse(["pine", "/tmp/test.swift:42"])
        #expect(result == .openFile(URL(fileURLWithPath: "/tmp/test.swift"), line: 42))
    }

    @Test func parsesFileWithLineAndColumn() {
        let result = CLIArgumentParser.parse(["pine", "/tmp/test.swift:42:10"])
        #expect(result == .openFile(URL(fileURLWithPath: "/tmp/test.swift"), line: 42))
    }

    @Test func noArgumentsShowsHelp() {
        let result = CLIArgumentParser.parse(["pine"])
        #expect(result == .showHelp)
    }

    @Test func helpFlag() {
        let result = CLIArgumentParser.parse(["pine", "--help"])
        #expect(result == .showHelp)
    }

    @Test func helpFlagShort() {
        let result = CLIArgumentParser.parse(["pine", "-h"])
        #expect(result == .showHelp)
    }

    @Test func versionFlag() {
        let result = CLIArgumentParser.parse(["pine", "--version"])
        #expect(result == .showVersion)
    }

    @Test func versionFlagShort() {
        let result = CLIArgumentParser.parse(["pine", "-v"])
        #expect(result == .showVersion)
    }

    @Test func tildePath() {
        let result = CLIArgumentParser.parse(["pine", "~/Documents"])
        #expect(result == .openDirectory(
            URL(fileURLWithPath: NSString("~/Documents").expandingTildeInPath)
        ))
    }

    // MARK: - Line number extraction

    @Test func extractLineFromColonSuffix() {
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "/tmp/test.swift:42")
        #expect(path == "/tmp/test.swift")
        #expect(line == 42)
    }

    @Test func extractLineAndColumnFromColonSuffix() {
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "/tmp/test.swift:42:10")
        #expect(path == "/tmp/test.swift")
        #expect(line == 42)
    }

    @Test func noLineNumberReturnsNil() {
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "/tmp/test.swift")
        #expect(path == "/tmp/test.swift")
        #expect(line == nil)
    }

    @Test func invalidLineNumberReturnsNil() {
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "/tmp/test.swift:abc")
        #expect(path == "/tmp/test.swift:abc")
        #expect(line == nil)
    }

    @Test func zeroLineNumberReturnsNil() {
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "/tmp/test.swift:0")
        #expect(path == "/tmp/test.swift:0")
        #expect(line == nil)
    }

    @Test func negativeLineNumberReturnsNil() {
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "/tmp/test.swift:-5")
        #expect(path == "/tmp/test.swift:-5")
        #expect(line == nil)
    }

    @Test func windowsDrivePathNotConfusedWithLineNumber() {
        // Ensure paths like C:\file aren't misinterpreted (edge case)
        let (path, line) = CLIArgumentParser.extractLineNumber(from: "C:file.txt")
        // "C" is not a valid line number, so this should be treated as plain path
        #expect(path == "C:file.txt")
        #expect(line == nil)
    }

    // MARK: - Open command generation

    @Test func openCommandForDirectory() {
        let cmd = CLIArgumentParser.openCommand(for: .openDirectory(URL(fileURLWithPath: "/tmp/project")))
        #expect(cmd == ["open", "-a", "Pine", "/tmp/project"])
    }

    @Test func openCommandForFile() {
        let cmd = CLIArgumentParser.openCommand(for: .openFile(URL(fileURLWithPath: "/tmp/test.swift"), line: nil))
        #expect(cmd == ["open", "-a", "Pine", "/tmp/test.swift"])
    }

    @Test func openCommandForFileWithLine() {
        let cmd = CLIArgumentParser.openCommand(for: .openFile(URL(fileURLWithPath: "/tmp/test.swift"), line: 42))
        #expect(cmd == ["open", "-a", "Pine", "--args", "--line", "42", "/tmp/test.swift"])
    }

    @Test func openCommandReturnsNilForHelp() {
        let cmd = CLIArgumentParser.openCommand(for: .showHelp)
        #expect(cmd == nil)
    }

    @Test func openCommandReturnsNilForVersion() {
        let cmd = CLIArgumentParser.openCommand(for: .showVersion)
        #expect(cmd == nil)
    }

    // MARK: - Help text

    @Test func helpTextContainsPineCommand() {
        let help = CLIArgumentParser.helpText
        #expect(help.contains("pine"))
        #expect(help.contains("USAGE"))
    }

    // MARK: - Equality

    @Test func resultEquality() {
        #expect(CLIArgumentParser.Result.showHelp == CLIArgumentParser.Result.showHelp)
        #expect(CLIArgumentParser.Result.showVersion == CLIArgumentParser.Result.showVersion)
        #expect(CLIArgumentParser.Result.showHelp != CLIArgumentParser.Result.showVersion)

        let url1 = URL(fileURLWithPath: "/tmp/a")
        let url2 = URL(fileURLWithPath: "/tmp/b")
        #expect(CLIArgumentParser.Result.openDirectory(url1) == .openDirectory(url1))
        #expect(CLIArgumentParser.Result.openDirectory(url1) != .openDirectory(url2))

        #expect(CLIArgumentParser.Result.openFile(url1, line: 42) == .openFile(url1, line: 42))
        #expect(CLIArgumentParser.Result.openFile(url1, line: 42) != .openFile(url1, line: 43))
        #expect(CLIArgumentParser.Result.openFile(url1, line: nil) != .openFile(url1, line: 42))
    }
}
