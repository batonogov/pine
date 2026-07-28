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
/// dispatched to `LanguageValidator` conformances (nonisolated) to avoid
/// `dispatch_assert_queue_fail` crashes under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
///
/// Uses protocol-based dispatch: the `validators` array holds all registered
/// `LanguageValidator` instances. Adding a new language only requires creating
/// a conforming type — no switch-cases to update.
@MainActor
@Observable
final class ConfigValidator {

    /// All registered language validators, dispatched by file extension/name.
    /// New languages are added by appending a `LanguageValidator` conforming type.
    let validators: [LanguageValidator] = [
        YAMLLanguageValidator(),
        ShellLanguageValidator(),
        DockerfileLanguageValidator(),
        TerraformLanguageValidator()
    ]

    /// Current diagnostics for the active file.
    private(set) var diagnostics: [ValidationDiagnostic] = []

    /// Exact editor content revision that produced `diagnostics`. `nil` means
    /// the caller did not supply a revision or no current result exists.
    private(set) var diagnosticsRevision: UInt64?

    /// Advances whenever a validation result is committed, including an empty
    /// result identical to the preceding one. Observing the diagnostics array
    /// alone misses that case and can leave an old revision attributed to new
    /// content in the project-wide Problems panel.
    private(set) var diagnosticsResultGeneration: UInt64 = 0

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
    func validate(url: URL, content: String, revision: UInt64? = nil) {
        debounceTask?.cancel()
        let currentGen = nextGeneration()

        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        let validator = validators.first { v in
            v.supportedExtensions.contains(ext)
                || v.supportedNames.contains(name)
                || v.supportedNamePrefixes.contains(where: { name.hasPrefix($0) })
        }

        guard let validator else {
            diagnostics = []
            diagnosticsRevision = revision
            diagnosticsResultGeneration &+= 1
            activeValidator = nil
            toolAvailable = false
            isValidating = false
            return
        }

        // Map to ValidatorKind for backward-compatible activeValidator display
        activeValidator = ValidatorDetector.detect(for: url)

        debounceTask = Task { [weak self] in
            // Debounce
            try? await Task.sleep(for: .seconds(Self.debounceInterval))
            guard !Task.isCancelled, let self else { return }

            self.runValidation(
                url: url,
                content: content,
                revision: revision,
                validator: validator,
                expectedGen: currentGen
            )
        }
    }

    /// Clears all diagnostics (e.g. when switching tabs).
    func clear() {
        debounceTask?.cancel()
        _ = nextGeneration()
        diagnostics = []
        diagnosticsRevision = nil
        diagnosticsResultGeneration &+= 1
        activeValidator = nil
        toolAvailable = false
        isValidating = false
    }

    // MARK: - Private

    private func runValidation(
        url: URL,
        content: String,
        revision: UInt64?,
        validator: LanguageValidator,
        expectedGen: UInt64
    ) {
        guard generation == expectedGen else { return }

        isValidating = true

        let capturedGen = expectedGen

        Task.detached {
            let result = validator.validate(url: url, content: content)

            await MainActor.run { [weak self] in
                guard let self, self.generation == capturedGen else { return }
                self.diagnostics = result.diagnostics
                self.diagnosticsRevision = revision
                self.diagnosticsResultGeneration &+= 1
                self.toolAvailable = result.toolAvailable
                self.isValidating = false
            }
        }
    }
}
