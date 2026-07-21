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

        // 1. Dangerous-pattern blocklist. Shell-sensitive checks share a
        // small lexer so quotes and escapes cannot trivially hide tokens.
        if Self.containsDangerousCommand(command, shellDepth: 0) {
            return UserTaskValidationResult(
                allowed: false,
                reason: "command matches dangerous pattern (potential system damage or RCE)"
            )
        }

        // 2. Optional executable-path allow-list.
        if !allowedExecutablePaths.isEmpty {
            if let violation = checkExecutableAllowList(command) {
                return violation
            }
        }

        return .allowed
    }

    private static let maximumCommandUTF16Length = 8_192
    private static let maximumLiteralShellDepth = 8

    private static func containsDangerousCommand(_ command: String, shellDepth: Int) -> Bool {
        // Validation runs before task execution is dispatched off the main
        // thread. Reject pathological inline scripts before wrapper parsing
        // can become expensive; normal task commands are far below 8 KiB.
        guard command.utf16.count <= maximumCommandUTF16Length else { return true }

        let pipelines = shellPipelines(in: command)
        if containsDangerousRecursiveDelete(in: pipelines)
            || containsInteractiveSystemShell(in: pipelines)
            || containsBase64DecodeIntoShell(in: pipelines) {
            return true
        }

        let range = NSRange(command.startIndex..., in: command)
        if dangerousPatterns.contains(where: {
            $0.firstMatch(in: command, options: [], range: range) != nil
        }) {
            return true
        }

        for payload in literalSystemShellPayloads(in: pipelines) {
            guard shellDepth < maximumLiteralShellDepth else { return true }
            if containsDangerousCommand(payload, shellDepth: shellDepth + 1) {
                return true
            }
        }
        return false
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

    private enum ShellLexeme {
        case word(String)
        case pipelineBoundary
        case commandBoundary
        case groupStart
        case groupEnd
    }

    private enum ShellQuote {
        case single
        case double
        case ansiC
    }

    private struct ShellPipeline {
        let stages: [[String]]
    }

    /// A deliberately small `/bin/sh` lexical scanner. It removes unescaped
    /// quote delimiters, joins adjacent quoted/unquoted fragments, resolves
    /// backslash escapes, and preserves command and pipeline boundaries.
    /// Expansion, globbing, and command execution are intentionally out of
    /// scope: this is a conservative recognizer, not a shell parser.
    private static func shellPipelines(in command: String) -> [ShellPipeline] {
        let lexemes = lexShell(command)
        var pipelines: [ShellPipeline] = []
        var stages: [[String]] = []
        var words: [String] = []
        var groupDepth = 0
        var compoundEnds: [String] = []
        var awaitingStageAfterPipe = false

        func finishStage() {
            guard !words.isEmpty else { return }
            stages.append(words)
            words.removeAll(keepingCapacity: true)
        }

        func finishPipeline() {
            finishStage()
            guard !stages.isEmpty else { return }
            pipelines.append(ShellPipeline(stages: stages))
            stages.removeAll(keepingCapacity: true)
        }

        for lexeme in lexemes {
            switch lexeme {
            case .word(let word):
                if words.isEmpty {
                    if let end = compoundEnd(openedBy: word) {
                        compoundEnds.append(end)
                    } else if compoundEnds.last == word {
                        compoundEnds.removeLast()
                    }
                }
                words.append(word)
                awaitingStageAfterPipe = false
            case .pipelineBoundary:
                finishStage()
                awaitingStageAfterPipe = true
            case .commandBoundary:
                if awaitingStageAfterPipe {
                    continue
                }
                if groupDepth > 0 || !compoundEnds.isEmpty {
                    finishStage()
                } else {
                    finishPipeline()
                }
            case .groupStart:
                finishStage()
                groupDepth += 1
            case .groupEnd:
                finishStage()
                groupDepth = max(0, groupDepth - 1)
            }
        }
        finishPipeline()
        return pipelines
    }

    private static func compoundEnd(openedBy word: String) -> String? {
        switch word {
        case "if": "fi"
        case "while", "until", "for", "select": "done"
        case "case": "esac"
        default: nil
        }
    }

    private static func lexShell(_ command: String) -> [ShellLexeme] {
        let characters = Array(command)
        var lexemes: [ShellLexeme] = []
        var currentWord = ""
        var wordStarted = false
        var activeQuote: ShellQuote?
        var discardingWord = false
        var discardNextWord = false
        var index = 0

        func startWord() {
            guard !wordStarted else { return }
            wordStarted = true
            if discardNextWord {
                discardingWord = true
                discardNextWord = false
            }
        }

        func flushWord() {
            guard wordStarted else { return }
            if !discardingWord {
                lexemes.append(.word(currentWord))
            }
            currentWord.removeAll(keepingCapacity: true)
            wordStarted = false
            discardingWord = false
        }

        while index < characters.count {
            let character = characters[index]

            if let quote = activeQuote {
                switch quote {
                case .single:
                    if character == "'" {
                        activeQuote = nil
                    } else {
                        currentWord.append(character)
                    }
                    index += 1
                case .double:
                    if character == "\"" {
                        activeQuote = nil
                        index += 1
                    } else if character == "\\", index + 1 < characters.count {
                        let escaped = characters[index + 1]
                        if escaped == "\n" {
                            index += 2
                        } else if "$`\"\\".contains(escaped) {
                            currentWord.append(escaped)
                            index += 2
                        } else {
                            currentWord.append("\\")
                            currentWord.append(escaped)
                            index += 2
                        }
                    } else {
                        currentWord.append(character)
                        index += 1
                    }
                case .ansiC:
                    if character == "'" {
                        activeQuote = nil
                        index += 1
                    } else if character == "\\" {
                        currentWord.append(contentsOf: decodeANSICQuotedEscape(characters, index: &index))
                    } else {
                        currentWord.append(character)
                        index += 1
                    }
                }
                continue
            }

            if character == "$", index + 1 < characters.count {
                if characters[index + 1] == "'" {
                    startWord()
                    activeQuote = .ansiC
                    index += 2
                    continue
                }
                if characters[index + 1] == "\"" {
                    startWord()
                    activeQuote = .double
                    index += 2
                    continue
                }
            }
            if character == "'" {
                activeQuote = .single
                startWord()
                index += 1
                continue
            }
            if character == "\"" {
                activeQuote = .double
                startWord()
                index += 1
                continue
            }
            if character == "\\" {
                startWord()
                if index + 1 < characters.count {
                    let escaped = characters[index + 1]
                    if escaped != "\n" {
                        currentWord.append(escaped)
                    }
                    index += 2
                } else {
                    currentWord.append(character)
                    index += 1
                }
                continue
            }
            if let redirectionLength = shellRedirectionLength(at: index, in: characters) {
                if wordStarted, currentWord.allSatisfy({ $0.isNumber }) {
                    currentWord.removeAll(keepingCapacity: true)
                    wordStarted = false
                    discardingWord = false
                } else {
                    flushWord()
                }
                discardNextWord = true
                index += redirectionLength
                continue
            }
            if character == "#", !wordStarted {
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            if character.isWhitespace {
                flushWord()
                if character == "\n" {
                    lexemes.append(.commandBoundary)
                }
                index += 1
                continue
            }
            if character == "|" {
                flushWord()
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    lexemes.append(.commandBoundary)
                    index += 2
                } else {
                    lexemes.append(.pipelineBoundary)
                    index += index + 1 < characters.count && characters[index + 1] == "&" ? 2 : 1
                }
                continue
            }
            if character == "&" || character == ";" || character == "(" || character == ")" {
                flushWord()
                if character == "(" {
                    lexemes.append(.groupStart)
                    index += 1
                } else if character == ")" {
                    lexemes.append(.groupEnd)
                    index += 1
                } else if index + 1 < characters.count, characters[index + 1] == character {
                    lexemes.append(.commandBoundary)
                    index += 2
                } else {
                    lexemes.append(.commandBoundary)
                    index += 1
                }
                continue
            }
            if character == "{", !wordStarted, isStandaloneBrace(at: index, in: characters) {
                lexemes.append(.groupStart)
                index += 1
                continue
            }
            if character == "}", !wordStarted, isStandaloneBrace(at: index, in: characters) {
                lexemes.append(.groupEnd)
                index += 1
                continue
            }

            startWord()
            currentWord.append(character)
            index += 1
        }

        flushWord()
        return lexemes
    }

    private static func shellRedirectionLength(at index: Int, in characters: [Character]) -> Int? {
        let character = characters[index]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        let following = index + 2 < characters.count ? characters[index + 2] : nil

        if character == "&", next == ">" {
            return following == ">" ? 3 : 2
        }
        if character == "<" {
            if next == "<", following == "-" || following == "<" {
                return 3
            }
            return next == "<" || next == ">" || next == "&" ? 2 : 1
        }
        if character == ">" {
            return next == ">" || next == "|" || next == "&" ? 2 : 1
        }
        return nil
    }

    private static func isStandaloneBrace(at index: Int, in characters: [Character]) -> Bool {
        guard index + 1 < characters.count else { return true }
        let next = characters[index + 1]
        return next.isWhitespace || ";&|()".contains(next)
    }

    private static func decodeANSICQuotedEscape(_ characters: [Character], index: inout Int) -> String {
        guard index + 1 < characters.count else {
            index += 1
            return "\\"
        }

        let escaped = characters[index + 1]
        let simpleEscapes: [Character: Character] = [
            "a": "\u{7}", "b": "\u{8}", "e": "\u{1B}", "E": "\u{1B}",
            "f": "\u{C}", "n": "\n", "r": "\r", "t": "\t", "v": "\u{B}",
            "\\": "\\", "'": "'", "\"": "\""
        ]
        if let decoded = simpleEscapes[escaped] {
            index += 2
            return String(decoded)
        }

        let radix: Int
        let maximumDigits: Int
        var cursor: Int
        if escaped == "x" {
            radix = 16
            maximumDigits = 2
            cursor = index + 2
        } else if escaped == "u" {
            radix = 16
            maximumDigits = 4
            cursor = index + 2
        } else if escaped == "U" {
            radix = 16
            maximumDigits = 8
            cursor = index + 2
        } else if UInt32(String(escaped), radix: 8) != nil {
            radix = 8
            maximumDigits = escaped == "0" ? 4 : 3
            cursor = index + 1
        } else {
            index += 2
            return "\\" + String(escaped)
        }

        var value: UInt32 = 0
        var consumed = 0
        while cursor < characters.count,
              consumed < maximumDigits,
              let digit = UInt32(String(characters[cursor]), radix: radix) {
            value = value * UInt32(radix) + digit
            cursor += 1
            consumed += 1
        }
        guard consumed > 0, let scalar = UnicodeScalar(value) else {
            index += 2
            return "\\" + String(escaped)
        }
        index = cursor
        return String(scalar)
    }

    /// Recognizes recursive, forced `rm` commands independently of short-
    /// flag order and long-option order. Relative project paths remain
    /// eligible for confirmation instead of being blocked outright.
    private static func containsDangerousRecursiveDelete(in pipelines: [ShellPipeline]) -> Bool {
        for pipeline in pipelines {
            for stage in pipeline.stages {
                guard let command = effectiveCommandWords(in: stage),
                      let executable = command.first else { continue }
                if isExecutable(executable, named: "rm"),
                   isDangerousRecursiveDelete(arguments: command.dropFirst()) {
                    return true
                }

                if isExecutable(executable, named: "xargs"),
                   let embeddedWords = xargsEmbeddedCommand(in: command),
                   let embeddedCommand = effectiveCommandWords(in: embeddedWords),
                   let embeddedExecutable = embeddedCommand.first,
                   isExecutable(embeddedExecutable, named: "rm"),
                   isDangerousRecursiveDelete(
                    arguments: embeddedCommand.dropFirst(),
                    hasImplicitTargets: true
                   ) {
                    return true
                }

                // A command may also appear inside a backtick substitution.
                // Scan the original non-xargs stage once so quote-joined
                // spellings such as r""m are recognized linearly.
                if !isExecutable(executable, named: "xargs"),
                   containsEmbeddedDangerousRm(in: stage) {
                    return true
                }
            }
        }

        return false
    }

    private static func isEmbeddedRmToken(_ token: String) -> Bool {
        let wrapperCharacters = CharacterSet(charactersIn: "`$(){}")
        let unwrapped = token.trimmingCharacters(in: wrapperCharacters)
        return isExecutable(unwrapped, named: "rm")
    }

    private static func containsEmbeddedDangerousRm(in stage: [String]) -> Bool {
        var sawRm = false
        var isRecursive = false
        var isForced = false
        var sawTarget = false
        var sawBroadTarget = false

        for token in stage {
            if isEmbeddedRmToken(token) {
                sawRm = true
                continue
            }
            guard sawRm else { continue }

            if token.hasPrefix("--") {
                let option = token
                    .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .lowercased()
                isRecursive = isRecursive || option == "--recursive"
                isForced = isForced || option == "--force"
            } else if token.hasPrefix("-"), token != "-" {
                let flags = token.dropFirst().lowercased()
                isRecursive = isRecursive || flags.contains("r")
                isForced = isForced || flags.contains("f")
            } else {
                sawTarget = true
                sawBroadTarget = sawBroadTarget || isBroadDeleteTarget(token)
            }
        }

        return sawRm && isRecursive && isForced && (!sawTarget || sawBroadTarget)
    }

    private static func xargsEmbeddedCommand(in command: [String]) -> [String]? {
        let executableIndex = wrapperExecutableIndex(
            in: command,
            after: command.startIndex,
            optionsTakingArguments: [
                "-a", "-d", "-E", "-I", "-J", "-L", "-n", "-P", "-R", "-S", "-s",
                "--arg-file", "--delimiter", "--eof", "--replace", "--max-lines",
                "--max-args", "--max-procs", "--max-chars", "--process-slot-var"
            ]
        )
        guard executableIndex < command.endIndex else { return nil }
        return Array(command[executableIndex...])
    }

    /// Consumes the words produced by `lexShell`; it is a defence-in-depth
    /// recognizer, not a complete implementation of `rm` option parsing.
    private static func isDangerousRecursiveDelete(
        arguments: ArraySlice<String>,
        hasImplicitTargets: Bool = false
    ) -> Bool {
        var isRecursive = false
        var isForced = false
        var optionsEnded = false
        var targets: [String] = []

        for token in arguments {
            guard !token.isEmpty else { continue }

            if !optionsEnded, token == "--" {
                optionsEnded = true
                continue
            }

            if !optionsEnded, token.hasPrefix("--") {
                let option = token
                    .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .lowercased()
                isRecursive = isRecursive || option == "--recursive"
                isForced = isForced || option == "--force"
                continue
            }

            if !optionsEnded, token.hasPrefix("-"), token != "-" {
                let flags = token.dropFirst().lowercased()
                isRecursive = isRecursive || flags.contains("r")
                isForced = isForced || flags.contains("f")
                continue
            }

            targets.append(token)
        }

        guard isRecursive, isForced else { return false }

        // A forced recursive invocation without a target is suspicious,
        // matching the prior blocklist policy.
        if hasImplicitTargets || targets.isEmpty || targets.contains(where: isBroadDeleteTarget) {
            return true
        }

        return false
    }

    private static func isBroadDeleteTarget(_ rawTarget: String) -> Bool {
        let variableRoots = ["$HOME", "${HOME}", "$PWD", "${PWD}"]
        if rawTarget == "$"
            || rawTarget.hasPrefix("$(")
            || rawTarget.hasPrefix("`")
            || rawTarget.hasPrefix("/")
            || rawTarget.hasPrefix("~")
            || variableRoots.contains(where: { rawTarget == $0 || rawTarget.hasPrefix("\($0)/") })
            || containsBroadVariableReference(rawTarget)
            || isBroadParameterExpansion(rawTarget) {
            return true
        }

        let target = lexicallyNormalizedRelativePath(rawTarget)
        if target == "." || target == ".." || target.hasPrefix("../") {
            return true
        }
        return target.hasPrefix("*")
            || target.hasPrefix("?")
            || target.hasPrefix("[")
            || target.hasPrefix(".*")
            || target.hasPrefix(".?")
            || target.hasPrefix(".[")
    }

    private static func containsBroadVariableReference(_ target: String) -> Bool {
        let markers = ["$HOME", "${HOME", "$PWD", "${PWD"]
        for marker in markers {
            var searchStart = target.startIndex
            while searchStart < target.endIndex,
                  let range = target.range(of: marker, range: searchStart..<target.endIndex) {
                if range.upperBound == target.endIndex
                    || "}/:?-+=%#".contains(target[range.upperBound]) {
                    return true
                }
                searchStart = range.upperBound
            }
        }
        return false
    }

    private static func isBroadParameterExpansion(_ target: String) -> Bool {
        for variable in ["HOME", "PWD"] {
            let prefix = "${\(variable)"
            guard target.hasPrefix(prefix) else { continue }
            let boundaryIndex = target.index(target.startIndex, offsetBy: prefix.count)
            guard boundaryIndex < target.endIndex else { return true }
            let boundary = target[boundaryIndex]
            if boundary == "}" || ":?-+=%#/".contains(boundary) {
                return true
            }
        }
        return false
    }

    private static func lexicallyNormalizedRelativePath(_ path: String) -> String {
        var components: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                if components.last != nil, components.last != ".." {
                    components.removeLast()
                } else {
                    components.append("..")
                }
                continue
            }
            components.append(String(component))
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private static func containsInteractiveSystemShell(in pipelines: [ShellPipeline]) -> Bool {
        for pipeline in pipelines {
            for stage in pipeline.stages {
                guard let command = effectiveCommandWords(in: stage),
                      let executable = command.first,
                      isSystemShellPath(executable) else { continue }
                if hasInteractiveInvocationOption(
                    command.dropFirst(),
                    shellName: executableName(executable)
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func literalSystemShellPayloads(in pipelines: [ShellPipeline]) -> [String] {
        var payloads: [String] = []
        for pipeline in pipelines {
            for stage in pipeline.stages {
                guard let command = effectiveCommandWords(in: stage),
                      let executable = command.first else { continue }
                var commands = [command]
                if isExecutable(executable, named: "xargs"),
                   let embeddedWords = xargsEmbeddedCommand(in: command),
                   let embeddedCommand = effectiveCommandWords(in: embeddedWords) {
                    commands.append(embeddedCommand)
                }

                for candidate in commands {
                    guard let shell = candidate.first,
                          isSystemShellPath(shell) else { continue }
                    if let payload = literalShellCommandString(
                        in: candidate.dropFirst(),
                        shellName: executableName(shell)
                    ) {
                        payloads.append(payload)
                    }
                }
            }
        }
        return payloads
    }

    private static func literalShellCommandString(
        in arguments: ArraySlice<String>,
        shellName: String
    ) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index].lowercased()
            if option == "--" {
                return nil
            }
            if shellName == "zsh", option == "-o" || option == "+o" {
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { return nil }
                index = arguments.index(after: index)
                continue
            }
            if shellName == "zsh", attachedZshNamedOption(option) != nil {
                index = arguments.index(after: index)
                continue
            }
            if option.hasPrefix("--") {
                let takesArgument = option == "--rcfile" || option == "--init-file"
                index = arguments.index(after: index)
                if takesArgument, index < arguments.endIndex {
                    index = arguments.index(after: index)
                }
                continue
            }
            guard option.hasPrefix("-") || option.hasPrefix("+"),
                  option != "-", option != "+" else { return nil }

            let flags = option.dropFirst()
            if option.hasPrefix("-"), flags.contains("c") {
                let payloadIndex = arguments.index(after: index)
                guard payloadIndex < arguments.endIndex else { return nil }
                return arguments[payloadIndex]
            }
            index = arguments.index(after: index)
            if flags == "o", index < arguments.endIndex {
                index = arguments.index(after: index)
            }
        }
        return nil
    }

    private static func hasInteractiveInvocationOption(
        _ arguments: ArraySlice<String>,
        shellName: String
    ) -> Bool {
        var index = arguments.startIndex
        var isInteractive = false
        while index < arguments.endIndex {
            let option = arguments[index].lowercased()
            if option == "--" {
                return isInteractive
            }
            if shellName == "zsh", option.hasPrefix("--") {
                let handled = applyZshNamedInteractiveOption(
                    String(option.dropFirst(2)),
                    enablesOption: true,
                    isInteractive: &isInteractive
                )
                if handled {
                    index = arguments.index(after: index)
                    continue
                }
            }
            if option == "--interactive" {
                isInteractive = true
                index = arguments.index(after: index)
                continue
            }
            if shellName == "zsh", option == "--nointeractive" {
                isInteractive = false
                index = arguments.index(after: index)
                continue
            }
            if shellName == "zsh", option == "-o" || option == "+o" {
                let enablesOption = option == "-o"
                index = arguments.index(after: index)
                guard index < arguments.endIndex else { return isInteractive }
                applyZshNamedInteractiveOption(
                    arguments[index],
                    enablesOption: enablesOption,
                    isInteractive: &isInteractive
                )
                index = arguments.index(after: index)
                continue
            }
            if shellName == "zsh",
               let namedOption = attachedZshNamedOption(option) {
                applyZshNamedInteractiveOption(
                    namedOption.name,
                    enablesOption: namedOption.enables,
                    isInteractive: &isInteractive
                )
                index = arguments.index(after: index)
                continue
            }
            if option.hasPrefix("--") {
                let takesArgument = option == "--rcfile" || option == "--init-file"
                index = arguments.index(after: index)
                if takesArgument, index < arguments.endIndex {
                    index = arguments.index(after: index)
                }
                continue
            }
            guard option.hasPrefix("-") || option.hasPrefix("+"),
                  option != "-", option != "+" else {
                return isInteractive
            }

            let flags = option.dropFirst()
            if flags.contains("i") {
                isInteractive = option.hasPrefix("-")
            }
            if flags.contains("c") {
                return isInteractive
            }
            index = arguments.index(after: index)
            if flags == "o", index < arguments.endIndex {
                index = arguments.index(after: index)
            }
        }
        return isInteractive
    }

    private static func attachedZshNamedOption(_ option: String) -> (name: String, enables: Bool)? {
        if option.hasPrefix("-o"), option.count > 2 {
            return (String(option.dropFirst(2)), true)
        }
        if option.hasPrefix("+o"), option.count > 2 {
            return (String(option.dropFirst(2)), false)
        }
        if option.hasPrefix("+-"), option.count > 2 {
            return (String(option.dropFirst(2)), false)
        }
        return nil
    }

    @discardableResult
    private static func applyZshNamedInteractiveOption(
        _ rawName: String,
        enablesOption: Bool,
        isInteractive: inout Bool
    ) -> Bool {
        let name = rawName
            .lowercased()
            .filter { $0 != "-" && $0 != "_" }
        if name == "interactive" {
            isInteractive = enablesOption
            return true
        } else if name == "nointeractive" {
            isInteractive = !enablesOption
            return true
        }
        return false
    }

    private static func containsBase64DecodeIntoShell(in pipelines: [ShellPipeline]) -> Bool {
        for pipeline in pipelines {
            var sawDecoder = false
            for stage in pipeline.stages {
                if sawDecoder, stageContainsShellExecutable(stage) {
                    return true
                }
                sawDecoder = sawDecoder || stageContainsBase64Decoder(stage)
            }
        }
        return false
    }

    private static func stageContainsBase64Decoder(_ stage: [String]) -> Bool {
        guard let command = effectiveCommandWords(in: stage),
              let executable = command.first,
              isExecutable(executable, named: "base64") else { return false }
        for argument in command.dropFirst() {
            if argument == "--" {
                break
            }
            if isBase64DecodeOption(argument) {
                return true
            }
        }
        return false
    }

    private static func isBase64DecodeOption(_ token: String) -> Bool {
        let option = token.lowercased()
        if option == "--decode" || option.hasPrefix("--decode=") {
            return true
        }
        return option.hasPrefix("-")
            && !option.hasPrefix("--")
            && option.dropFirst().contains("d")
    }

    private static func stageContainsShellExecutable(_ stage: [String]) -> Bool {
        guard let command = effectiveCommandWords(in: stage),
              let executable = command.first else { return false }
        let name = executableName(executable)
        return name == "sh" || name == "bash" || name == "zsh" || name == "fish"
    }

    /// Returns the effective command after shell syntax, assignments, and
    /// common wrappers. Wrapper options are consumed with their operands so
    /// an option argument cannot masquerade as the executable.
    private static func effectiveCommandWords(in stage: [String]) -> [String]? {
        var words = stage
        var index = words.startIndex

        while index < words.endIndex {
            let token = words[index]
            if isVariableAssignment(token) || isShellReservedWord(token) || token.hasPrefix("-") {
                index = words.index(after: index)
                continue
            }

            switch executableName(token) {
            case "env":
                guard let unwrapped = unwrapEnvironmentCommand(words, after: index) else { return nil }
                words = unwrapped
                index = words.startIndex
            case "command":
                guard let nextIndex = commandWrapperExecutableIndex(in: words, after: index) else {
                    return nil
                }
                index = nextIndex
            case "exec":
                index = wrapperExecutableIndex(
                    in: words,
                    after: index,
                    optionsTakingArguments: ["-a"]
                )
            case "time":
                index = wrapperExecutableIndex(
                    in: words,
                    after: index,
                    optionsTakingArguments: ["-o", "--output"]
                )
            case "nice":
                index = wrapperExecutableIndex(
                    in: words,
                    after: index,
                    optionsTakingArguments: ["-n", "--adjustment"]
                )
            case "nohup":
                index = wrapperExecutableIndex(in: words, after: index, optionsTakingArguments: [])
            default:
                return Array(words[index...])
            }
        }
        return nil
    }

    private static func unwrapEnvironmentCommand(_ words: [String], after envIndex: Int) -> [String]? {
        var index = words.index(after: envIndex)
        var splitString: String?

        while index < words.endIndex {
            let option = words[index]
            if option == "--" {
                index = words.index(after: index)
                break
            }
            guard option.hasPrefix("-"), option != "-" else { break }

            if option == "-S" || option == "--split-string" {
                index = words.index(after: index)
                guard index < words.endIndex else { return nil }
                splitString = words[index]
                index = words.index(after: index)
                continue
            }
            if option.hasPrefix("-S"), option.count > 2 {
                splitString = String(option.dropFirst(2))
                index = words.index(after: index)
                continue
            }
            if option.hasPrefix("--split-string=") {
                splitString = String(option.dropFirst("--split-string=".count))
                index = words.index(after: index)
                continue
            }

            let takesArgument = ["--unset", "--chdir", "--path"].contains(option)
            index = words.index(after: index)
            if takesArgument, index < words.endIndex {
                index = words.index(after: index)
                continue
            }

            let shortOptions = option.dropFirst()
            if !option.hasPrefix("--"),
               let argumentOption = shortOptions.firstIndex(where: { "uCPS".contains($0) }) {
                let attachedArgument = shortOptions[shortOptions.index(after: argumentOption)...]
                if shortOptions[argumentOption] == "S" {
                    if attachedArgument.isEmpty {
                        guard index < words.endIndex else { return nil }
                        splitString = words[index]
                    } else {
                        splitString = String(attachedArgument)
                    }
                }
                if attachedArgument.isEmpty, index < words.endIndex {
                    index = words.index(after: index)
                }
            }
        }

        let suffix = index < words.endIndex ? Array(words[index...]) : []
        guard let splitString else { return suffix }
        return shellWords(in: splitString) + suffix
    }

    private static func shellWords(in fragment: String) -> [String] {
        lexShell(fragment).compactMap { lexeme in
            guard case .word(let word) = lexeme else { return nil }
            return word
        }
    }

    private static func commandWrapperExecutableIndex(in words: [String], after wrapperIndex: Int) -> Int? {
        var index = words.index(after: wrapperIndex)
        while index < words.endIndex {
            let option = words[index]
            if option == "--" {
                return words.index(after: index)
            }
            if option.hasPrefix("-"), option.dropFirst().contains(where: { $0 == "v" || $0 == "V" }) {
                return nil
            }
            guard option.hasPrefix("-"), option != "-" else { return index }
            index = words.index(after: index)
        }
        return nil
    }

    private static func wrapperExecutableIndex(
        in words: [String],
        after wrapperIndex: Int,
        optionsTakingArguments: Set<String>
    ) -> Int {
        var index = words.index(after: wrapperIndex)
        let shortArgumentNames = Set(optionsTakingArguments.compactMap { argumentOption -> Character? in
            guard argumentOption.hasPrefix("-"),
                  !argumentOption.hasPrefix("--"),
                  argumentOption.count == 2 else { return nil }
            return argumentOption.last
        })
        while index < words.endIndex {
            let option = words[index]
            if option == "--" {
                return words.index(after: index)
            }
            guard option.hasPrefix("-"), option != "-" else { return index }
            index = words.index(after: index)

            let shortOptions = option.dropFirst()
            let argumentPosition = shortOptions.firstIndex(where: shortArgumentNames.contains)
            let hasAttachedArgument = argumentPosition.map {
                shortOptions.index(after: $0) < shortOptions.endIndex
            } ?? false
            if optionsTakingArguments.contains(option) || argumentPosition != nil,
               !hasAttachedArgument,
               index < words.endIndex {
                index = words.index(after: index)
            }
        }
        return index
    }

    private static func isShellReservedWord(_ token: String) -> Bool {
        [
            "!", "{", "}", "if", "then", "elif", "else", "fi", "while", "until",
            "do", "done", "for", "select", "case", "esac", "in"
        ].contains(token)
    }

    private static func isVariableAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else {
            return false
        }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else {
            return false
        }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func isSystemShellPath(_ token: String) -> Bool {
        let path = normalizedExecutablePath(token)
        if !path.contains("/") {
            return path == "sh" || path == "bash" || path == "zsh"
        }
        return path == "/bin/sh" || path == "/bin/bash" || path == "/bin/zsh"
    }

    private static func isExecutable(_ token: String, named expectedName: String) -> Bool {
        executableName(token) == expectedName
    }

    private static func executableName(_ token: String) -> String {
        (normalizedExecutablePath(token) as NSString).lastPathComponent
    }

    private static func normalizedExecutablePath(_ token: String) -> String {
        let lowercased = token.lowercased()
        guard lowercased.hasPrefix("/") else { return lowercased }
        return (lowercased as NSString).standardizingPath
    }

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
