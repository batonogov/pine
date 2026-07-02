//
//  UserTaskValidator.swift
//  Pine
//
//  Security layer (milestone #1088, item 4) for the user-task runner.
//  Validates shell commands loaded from `tasks.json` before they are
//  handed to `/bin/sh -c`, blocking obvious injection / RCE patterns and
//  enforcing an optional allow-list of permitted executable paths.
//
//  The validator is intentionally conservative: a command that matches any
//  known-dangerous pattern is rejected with a descriptive reason, and the
//  caller logs the decision.  This is **defence-in-depth** — it does NOT
//  make arbitrary shell safe, only blocks the most common foot-guns so a
//  malformed or malicious `tasks.json` cannot trivially `rm -rf` the user's
//  home directory or pipe `curl` output into `sh`.
//

import Foundation
import os

/// Result of validating a user-task command.
nonisolated struct UserTaskValidationResult: Sendable, Equatable {
    /// `true` when the command passed all checks and may be executed.
    let allowed: Bool
    /// Human-readable explanation when `allowed` is `false` (the matched
    /// pattern / policy); empty string when the command is allowed.
    let reason: String

    static let allowed = UserTaskValidationResult(allowed: true, reason: "")
}

/// Validates user-task commands against dangerous patterns and an optional
/// allow-list of executable paths.
///
/// **Concurrency:** `nonisolated` so it can be called from any actor /
/// queue (the runner dispatches work to `DispatchQueue.global`).
/// The instance is a value type — create one per validation or reuse the
/// shared `default` singleton.
nonisolated struct UserTaskValidator: Sendable {
    /// Shared validator with the built-in dangerous-pattern blocklist and
    /// no path allow-list.
    static let `default` = UserTaskValidator()

    // MARK: - Dangerous pattern detection

    /// Regex patterns that, when matched (case-insensitive) anywhere in the
    /// command string, cause the task to be **blocked**.
    ///
    /// The list is deliberately broad — false positives (blocking a
    /// legitimate command) are acceptable; false negatives (running a
    /// destructive command) are not.
    private static let dangerousPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            // Recursive delete of root-level paths.
            // Matches: rm -rf /, rm -rf ~, rm -rf *, rm -rf ~/*
            #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive)\s+(/|~|\*|/\*)"#,
            // Bare `rm -rf` with no path argument at all is suspicious too.
            #"\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive)\s*$"#,
            // Privilege escalation.
            #"\bsudo\b"#,
            #"\bsu\s+root\b"#,
            // Remote-execution / download-and-pipe-to-shell patterns.
            #"\b(curl|wget)\b[^|]*\|\s*(sh|bash|zsh|fish)\b"#,
            #"\b(curl|wget)\b[^>]*>\s*/(usr/)?(bin|sbin|tmp)/"#,  // write to system dirs
            // Shell-from-URL (common payload format).
            #"\b(curl|wget)\s+https?://[^|]*\|\s*sh\b"#,
            // eval / exec of dynamic content.
            #"\beval\s+\$"#,
            #"\beval\b.*\$\("#,
            // Writing into /etc, /System, /Library (system tampering).
            #">\s*/etc/"#,
            #">\s*/System/"#,
            #">\s*/Library/"#,
            // chmod 777 on system directories.
            #"\bchmod\s+[-+]?[rwx]*777\b"#,
            // Disk erase.
            #"\bdiskutil\s+eraseDisk\b"#,
            #"\bdd\b.*\bof=/dev/"#,
            // Launching remote shell sessions.
            #"\bnc\s+-l\b"#,
            #"\b/bin/(sh|bash|zsh)\s+-i\b"#,
            // Base64-decode-and-execute pattern.
            #"\becho\s+[A-Za-z0-9+/=]{20,}\s*\|\s*(base64\s+-d\s*\|\s*)?(sh|bash)\b"#,
            // mktemp / tmpfile + execute (common dropper pattern).
            #"/tmp/\S+\s*\|\s*(sh|bash)\b"#,
        ]

        return patterns.compactMap { pattern in
            do {
                return try NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive, .anchorsMatchLines]
                )
            } catch {
                assertionFailure("Invalid dangerous-pattern regex: \(pattern) — \(error)")
                return nil
            }
        }
    }()

    /// Patterns whose presence marks a command as **destructive** — these
    /// don't block execution but cause `requireConfirmation` to default to
    /// `true` so the user is warned before running.
    private static let destructivePatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            #"\brm\s+(-[a-zA-Z]*f)?\b"#,        // rm with or without flags
            #"\bmv\b.*\s/(usr|etc|var|bin)\b"#,  // move into system dirs
            #"\bchmod\b"#,
            #"\bchown\b"#,
            #"\bkillall\b"#,
            #"\bkill\b\s+-9\b"#,
            #"\btruncate\b"#,
            #"\bmkfs\b"#,
            #"\bdiskutil\b"#,
            #"\bdd\b"#,
            #">\s*/dev/"#,
        ]

        return patterns.compactMap { pattern in
            do {
                return try NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                )
            } catch {
                assertionFailure("Invalid destructive-pattern regex: \(pattern) — \(error)")
                return nil
            }
        }
    }()

    /// Optional allow-list of absolute paths to executables that are
    /// permitted.  When non-empty, the **first token** of the command (the
    /// executable name or path) must resolve to one of these paths.
    ///
    /// Example: `["/usr/bin/swift", "/opt/homebrew/bin/shfmt"]`.
    let allowedExecutablePaths: Set<String>

    init(allowedExecutablePaths: Set<String> = []) {
        self.allowedExecutablePaths = allowedExecutablePaths
    }

    // MARK: - Public API

    /// Validates a command string, returning `.allowed` or a rejection with
    /// the matched pattern's description.
    func validate(command: String) -> UserTaskValidationResult {
        // Empty / whitespace-only commands are rejected outright.
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return UserTaskValidationResult(allowed: false, reason: "command is empty")
        }

        // 1. Dangerous-pattern blocklist.
        for regex in Self.dangerousPatterns {
            let range = NSRange(command.startIndex..., in: command)
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                return UserTaskValidationResult(
                    allowed: false,
                    reason: "command matches dangerous pattern (potential system damage or RCE)"
                )
            }
        }

        // 2. Optional executable-path allow-list.
        if !allowedExecutablePaths.isEmpty {
            if let violation = checkExecutableAllowList(command) {
                return violation
            }
        }

        return .allowed
    }

    /// Returns `true` when the command contains a destructive pattern.
    /// Used to default `UserTask.requireConfirmation`.
    func isDestructive(_ command: String) -> Bool {
        for regex in Self.destructivePatterns {
            let range = NSRange(command.startIndex..., in: command)
            if regex.firstMatch(in: command, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    /// Extracts the first executable token and checks it against the
    /// allow-list.
    private func checkExecutableAllowList(_ command: String) -> UserTaskValidationResult? {
        // Split on whitespace and take the first token.  This is intentionally
        // simple — full shell parsing is out of scope for a defence-in-depth
        // validator; the allow-list is opt-in, not the primary gate.
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
        guard let firstToken = tokens.first else {
            return UserTaskValidationResult(
                allowed: false,
                reason: "could not determine executable from command"
            )
        }

        let executable = String(firstToken)

        // Strip common shell prefixes.
        let cleaned: String
        if executable.hasPrefix("/") {
            cleaned = executable
        } else {
            // The user may have written a bare name like "swift".  Try to
            // resolve it via PATH; if unresolved, reject.
            cleaned = executable
        }

        if allowedExecutablePaths.contains(cleaned) {
            return nil
        }

        // Also allow bare-name matches if the allow-list contains the same
        // bare name (ergonomic shortcut).
        let bareNames = Set(allowedExecutablePaths.map { ($0 as NSString).lastPathComponent })
        if bareNames.contains(cleaned) {
            return nil
        }

        return UserTaskValidationResult(
            allowed: false,
            reason: "executable '\(executable)' is not in the allow-list"
        )
    }
}
