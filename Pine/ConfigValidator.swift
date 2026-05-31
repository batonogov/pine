//
//  ConfigValidator.swift
//  Pine
//
//  Created by Claude on 29.03.2026.
//
//  Facade: composes per-language validators defined in Pine/Validators/.
//  Language-specific logic lives in YAMLValidator, ShellValidator,
//  DockerfileValidator, TerraformValidator, and ValidationWorker.
//

import Foundation

// MARK: - Output Parsers (namespace)

/// Parses output from various config validators into diagnostics.
/// Extensions in YAMLValidator, ShellValidator, DockerfileValidator, TerraformValidator.
nonisolated enum ValidatorOutputParser {}

// MARK: - Built-in Validators (namespace)

/// Built-in regex-based validators that work without external tools.
/// Extensions in YAMLValidator, ShellValidator, DockerfileValidator.
nonisolated enum BuiltinValidator {}

// MARK: - ConfigValidator

/// Runs external config validators and produces diagnostics.
/// Falls back to built-in regex-based validators when external tools are not installed.
/// Explicitly `@MainActor` — all UI state lives here. Heavy validation work is
/// dispatched to `ConfigValidationWorker` (nonisolated) to avoid
/// `dispatch_assert_queue_fail` crashes under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
@MainActor
@Observable
final class ConfigValidator {

    /// Current diagnostics for the active file.
    private(set) var diagnostics: [ValidationDiagnostic] = []

    /// Whether validation is currently running.
    private(set) var isValidating = false

    /// The validator kind for the current file, if any.
    private(set) var activeValidator: ValidatorKind?

    /// Whether the required tool is available.
    private(set) var toolAvailable = false

    /// Debounce interval in seconds.
    nonisolated static let debounceInterval: TimeInterval = UITimings.Debounce.configValidation

    /// Generation token to discard stale results.
    private var generation: UInt64 = 0

    /// Debounce task handle.
    private var debounceTask: Task<Void, Never>?

    /// Increments and returns the new generation token.
    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Validates the given file content, debounced.
    /// - Parameters:
    ///   - url: The file URL (used for extension detection and temp file creation).
    ///   - content: The current file content.
    func validate(url: URL, content: String) {
        debounceTask?.cancel()

        guard let kind = ValidatorDetector.detect(for: url) else {
            diagnostics = []
            activeValidator = nil
            toolAvailable = false
            return
        }

        let currentGen = nextGeneration()

        debounceTask = Task { [weak self] in
            // Debounce
            try? await Task.sleep(for: .seconds(Self.debounceInterval))
            guard !Task.isCancelled, let self else { return }

            self.runValidation(url: url, content: content, kind: kind, expectedGen: currentGen)
        }
    }

    /// Clears all diagnostics (e.g. when switching tabs).
    func clear() {
        debounceTask?.cancel()
        _ = nextGeneration()
        diagnostics = []
        activeValidator = nil
        toolAvailable = false
        isValidating = false
    }

    // MARK: - Private

    private func runValidation(url: URL, content: String, kind: ValidatorKind, expectedGen: UInt64) {
        guard generation == expectedGen else { return }

        isValidating = true
        activeValidator = kind

        let capturedGen = expectedGen

        Task.detached {
            let result = ConfigValidationWorker.runValidation(url: url, content: content, kind: kind)

            await MainActor.run { [weak self] in
                guard let self, self.generation == capturedGen else { return }
                self.diagnostics = result.diagnostics
                self.toolAvailable = result.toolAvailable
                self.isValidating = false
            }
        }
    }
}
