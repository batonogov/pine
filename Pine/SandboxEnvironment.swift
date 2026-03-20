//
//  SandboxEnvironment.swift
//  Pine
//
//  Created by Claude on 20.03.2026.
//

import Foundation

/// Runtime detection of App Sandbox and feature availability.
///
/// Pine ships a single binary for both Homebrew/DMG and Mac App Store.
/// The App Store build enables App Sandbox via entitlements, which disables
/// features that require process spawning (terminal, git CLI).
/// This enum centralizes all sandbox-aware feature gating.
enum SandboxEnvironment {

    /// Whether the app is running inside App Sandbox.
    ///
    /// macOS sets the `APP_SANDBOX_CONTAINER_ID` environment variable
    /// for sandboxed processes.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Terminal requires PTY/fork, which is unavailable in App Sandbox.
    static var isTerminalAvailable: Bool {
        !isSandboxed
    }

    /// Git status/diff uses `Process("/usr/bin/git")`, unavailable in App Sandbox.
    static var isGitAvailable: Bool {
        !isSandboxed
    }
}
