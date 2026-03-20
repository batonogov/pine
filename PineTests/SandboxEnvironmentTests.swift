//
//  SandboxEnvironmentTests.swift
//  PineTests
//
//  Created by Claude on 20.03.2026.
//

import Testing
@testable import Pine

@Suite("SandboxEnvironment")
struct SandboxEnvironmentTests {

    @Test("isSandboxed returns false in test environment")
    func isSandboxedReturnsFalse() {
        // Tests run outside of App Sandbox, so this should always be false.
        #expect(!SandboxEnvironment.isSandboxed)
    }

    @Test("isTerminalAvailable is true when not sandboxed")
    func terminalAvailableOutsideSandbox() {
        #expect(SandboxEnvironment.isTerminalAvailable == !SandboxEnvironment.isSandboxed)
    }

    @Test("isGitAvailable is true when not sandboxed")
    func gitAvailableOutsideSandbox() {
        #expect(SandboxEnvironment.isGitAvailable == !SandboxEnvironment.isSandboxed)
    }

    @Test("Feature set is consistent")
    func featureSetConsistency() {
        // When not sandboxed, all features should be available.
        if !SandboxEnvironment.isSandboxed {
            #expect(SandboxEnvironment.isTerminalAvailable)
            #expect(SandboxEnvironment.isGitAvailable)
        }
    }
}
