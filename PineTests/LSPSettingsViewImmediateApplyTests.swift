//
//  LSPSettingsViewImmediateApplyTests.swift
//  PineTests
//
//  Tests for the immediate-apply LSP Settings contract (issue #1242):
//    • Per-language drafts survive language switches
//    • Invalid partial text is never persisted
//    • Valid edits persist atomically as soon as they validate
//    • Reset clears both the override and the in-memory draft
//

import Foundation
import Testing

@testable import Pine

@Suite("LSP Settings Immediate Apply")
@MainActor
struct LSPSettingsViewImmediateApplyTests {
    private func makeDefaults() -> UserDefaults {
        let name = "LSPSettingsViewImmediateApply-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Failed to create test defaults")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Atomic persistence of valid overrides

    @Test("A valid override is persisted atomically and survives relaunch")
    func validOverridePersistsAtomically() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["--stdio", "--log"]
        )

        // The override is immediately visible.
        let override = settings.serverOverride(for: "swift")
        #expect(override != nil)
        #expect(override?.executablePath == "/bin/echo")
        #expect(override?.arguments == ["--stdio", "--log"])

        // Atomic: a fresh LSPSettings instance reads the same value.
        let relaunched = LSPSettings(defaults: defaults)
        #expect(
            relaunched.serverOverride(for: "swift")
                == LanguageServerOverride(
                    executablePath: "/bin/echo",
                    arguments: ["--stdio", "--log"]
                )
        )
    }

    // MARK: - Invalid partial text is never persisted

    @Test("Invalid path is rejected and does not pollute the override store")
    func invalidPathNotPersisted() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        // Start with a valid override.
        try settings.setServerOverride(
            language: "typescript",
            executablePath: "/bin/echo",
            arguments: nil
        )

        // Attempt to set an invalid (relative) path — as a user typing a
        // partial path would.
        #expect(throws: LSPSettingsValidationError.pathMustBeAbsolute) {
            try settings.setServerOverride(
                language: "typescript",
                executablePath: "relative/partial",
                arguments: nil
            )
        }

        // The original valid override is untouched.
        #expect(
            settings.serverOverride(for: "typescript")?.executablePath
                == "/bin/echo"
        )
    }

    @Test("Invalid arguments are rejected and do not pollute the override store")
    func invalidArgumentsNotPersisted() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        try settings.setServerOverride(
            language: "python",
            executablePath: "/usr/bin/true",
            arguments: ["--stdio"]
        )

        // An argument containing a newline is invalid — represents a user
        // mid-edit in the arguments text editor.
        #expect(
            throws: LSPSettingsValidationError.invalidArgument(index: 1)
        ) {
            try settings.setServerOverride(
                language: "python",
                executablePath: "/usr/bin/true",
                arguments: ["--stdio", "bad\nargument"]
            )
        }

        // Original arguments survive.
        #expect(
            settings.serverOverride(for: "python")?.arguments
                == ["--stdio"]
        )
    }

    // MARK: - Per-language independence (drafts don't leak)

    @Test("Overrides for different languages are fully independent")
    func perLanguageDraftsIndependent() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        // Set swift to a valid path.
        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: ["--swift-arg"]
        )

        // Attempt an invalid override for typescript — must not affect swift.
        #expect(throws: LSPSettingsValidationError.pathDoesNotExist) {
            try settings.setServerOverride(
                language: "typescript",
                executablePath: "/nonexistent/server",
                arguments: nil
            )
        }

        #expect(
            settings.serverOverride(for: "swift")?.arguments
                == ["--swift-arg"]
        )
        #expect(settings.serverOverride(for: "typescript") == nil)
    }

    // MARK: - Reset clears the override

    @Test("Reset removes the persisted override so defaults are inherited")
    func resetClearsOverride() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: nil
        )
        #expect(settings.serverOverride(for: "swift") != nil)

        settings.resetServerOverride(language: "swift")
        #expect(settings.serverOverride(for: "swift") == nil)

        // Relaunch confirms the reset persisted.
        let relaunched = LSPSettings(defaults: defaults)
        #expect(relaunched.serverOverride(for: "swift") == nil)
    }

    @Test("Resetting a language with no override is a no-op")
    func resetNoOverrideIsNoOp() {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        // No override exists — reset should not crash or error.
        settings.resetServerOverride(language: "swift")
        #expect(settings.serverOverride(for: "swift") == nil)
    }

    // MARK: - Blank normalization

    @Test("Empty executable path normalizes to nil (inherit default)")
    func emptyPathNormalizesToNil() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        // Blank path + nil arguments → no override stored.
        try settings.setServerOverride(
            language: "swift",
            executablePath: "",
            arguments: nil
        )
        #expect(settings.serverOverride(for: "swift") == nil)

        // Whitespace-only path also normalizes to nil.
        try settings.setServerOverride(
            language: "swift",
            executablePath: "  \t ",
            arguments: nil
        )
        #expect(settings.serverOverride(for: "swift") == nil)
    }

    @Test("Empty arguments array means launch without arguments")
    func emptyArgumentsArrayMeansNoArgs() throws {
        let defaults = makeDefaults()
        let settings = LSPSettings(defaults: defaults)

        try settings.setServerOverride(
            language: "swift",
            executablePath: "/bin/echo",
            arguments: []
        )

        let override = settings.serverOverride(for: "swift")
        // An explicit empty array is distinct from nil — it means "launch
        // with no arguments" rather than "inherit default arguments".
        #expect(override?.arguments == [])
        #expect(override?.executablePath == "/bin/echo")
    }
}
