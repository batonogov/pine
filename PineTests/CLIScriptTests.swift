//
//  CLIScriptTests.swift
//  PineTests
//
//  Tests the pine shell script by invoking it with various arguments
//  and checking stdout/exit codes (without actually launching Pine).
//

import Foundation
import Testing

@testable import Pine

struct CLIScriptTests {
    /// Path to the bundled pine script in the test host's resources.
    private var scriptPath: String? {
        Bundle(for: BundleLocator.self).path(forResource: "pine", ofType: nil)
    }

    private func runScript(_ args: [String], env: [String: String]? = nil) throws -> (output: String, exitCode: Int32) {
        guard let path = scriptPath else {
            throw ScriptError.scriptNotFound
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path] + args
        if let env {
            var environment = ProcessInfo.processInfo.environment
            environment.merge(env) { _, new in new }
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    enum ScriptError: Error {
        case scriptNotFound
    }

    @Test func helpFlagShowsUsage() throws {
        guard scriptPath != nil else { return }
        let result = try runScript(["--help"])
        #expect(result.output.contains("USAGE"))
        #expect(result.output.contains("pine"))
        #expect(result.exitCode == 0)
    }

    @Test func shortHelpFlagShowsUsage() throws {
        guard scriptPath != nil else { return }
        let result = try runScript(["-h"])
        #expect(result.output.contains("USAGE"))
        #expect(result.exitCode == 0)
    }

    @Test func noArgumentsShowsHelp() throws {
        guard scriptPath != nil else { return }
        let result = try runScript([])
        #expect(result.output.contains("USAGE"))
        #expect(result.exitCode == 0)
    }

    @Test func versionFlagShowsVersion() throws {
        guard scriptPath != nil else { return }
        let result = try runScript(["--version"])
        #expect(result.output.contains("Pine"))
        #expect(result.exitCode == 0)
    }
}

/// Helper class to locate the test bundle.
private class BundleLocator {}
