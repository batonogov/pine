//
//  CLIInstallerTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

struct CLIInstallerTests {
    @Test func defaultInstallPathIsUsrLocalBin() {
        #expect(CLIInstaller.defaultInstallPath == "/usr/local/bin/pine")
    }

    @Test func isInstalledReturnsBoolBasedOnFileExistence() {
        // This just verifies the property doesn't crash — actual value depends on system state
        _ = CLIInstaller.isInstalled
    }

    @Test func isInstalledFromCurrentBundleReturnsBool() {
        _ = CLIInstaller.isInstalledFromCurrentBundle
    }
}
