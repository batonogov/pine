//
//  ShellAutosuggestionsTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("ShellAutosuggestions Tests")
struct ShellAutosuggestionsTests {

    // MARK: - Helpers

    private func makeTempProvider() throws -> (ShellAutosuggestionsProvider, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-autosuggest-\(UUID().uuidString)", isDirectory: true)
        let provider = ShellAutosuggestionsProvider(directory: tmp)
        return (provider, tmp)
    }

    // MARK: - generateZshrc()

    @Test func generatedZshrcContainsHeader() {
        let script = ShellAutosuggestionsProvider.generateZshrc()
        #expect(script.contains("# Pine"))
        #expect(script.contains("Generated automatically"))
    }

    @Test func generatedZshrcSourcesUserRealZshrc() {
        let script = ShellAutosuggestionsProvider.generateZshrc()
        // Must source the user's real ~/.zshrc so everything (oh-my-zsh,
        // starship, direnv, nvm, vim integration) keeps working.
        #expect(script.contains("$HOME/.zshrc"))
        #expect(script.contains("ZDOTDIR=\"$HOME\""))
    }

    @Test func generatedZshrcSourcesUserZshrcBeforePlugin() {
        // Order matters: user config first, plugin second, so the plugin
        // can observe whatever options the user's config set.
        let script = ShellAutosuggestionsProvider.generateZshrc()
        let userIdx = script.range(of: "$HOME/.zshrc")?.lowerBound
        let pluginIdx = script.range(of: "zsh-autosuggestions.zsh")?.lowerBound
        #expect(userIdx != nil && pluginIdx != nil)
        if let u = userIdx, let p = pluginIdx {
            #expect(u < p)
        }
    }

    @Test func generatedZshrcIteratesAllCandidatePaths() {
        let script = ShellAutosuggestionsProvider.generateZshrc()
        for candidate in ShellAutosuggestionsProvider.candidateAutosuggestionPaths {
            #expect(script.contains(candidate), "Candidate not referenced: \(candidate)")
        }
    }

    @Test func generatedZshrcIncludesHomebrewArmAndIntelPaths() {
        let paths = ShellAutosuggestionsProvider.candidateAutosuggestionPaths
        #expect(paths.contains("/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh"))
        #expect(paths.contains("/usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh"))
    }

    @Test func generatedZshrcIncludesOhMyZshPath() {
        let paths = ShellAutosuggestionsProvider.candidateAutosuggestionPaths
        #expect(paths.contains { $0.contains(".oh-my-zsh") })
    }

    @Test func generatedZshrcUsesBrightBlackHighlightStyle() {
        // Ghost text must use ANSI slot 8 to match Pine's Terminal.app palette
        // fix in #765.
        let script = ShellAutosuggestionsProvider.generateZshrc()
        #expect(script.contains("ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE"))
        #expect(script.contains("fg=8"))
    }

    @Test func generatedZshrcIsDeterministic() {
        // Same input → same output, so install() can short-circuit on equality.
        let a = ShellAutosuggestionsProvider.generateZshrc()
        let b = ShellAutosuggestionsProvider.generateZshrc()
        #expect(a == b)
    }

    @Test func generatedZshrcHasNoCRLFLineEndings() {
        // A zshrc with \r\n breaks zsh on some systems.
        let script = ShellAutosuggestionsProvider.generateZshrc()
        #expect(!script.contains("\r"))
    }

    // MARK: - install() / uninstall()

    @Test func installCreatesDirectoryAndZshrc() throws {
        let (provider, tmp) = try makeTempProvider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try provider.install()
        #expect(result == tmp)
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        #expect(FileManager.default.fileExists(atPath: provider.zshrcURL.path))
    }

    @Test func installWritesCorrectContents() throws {
        let (provider, tmp) = try makeTempProvider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try provider.install()
        let written = try String(contentsOf: provider.zshrcURL, encoding: .utf8)
        #expect(written == ShellAutosuggestionsProvider.generateZshrc())
    }

    @Test func installIsIdempotent() throws {
        let (provider, tmp) = try makeTempProvider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try provider.install()
        let mtime1 = try FileManager.default
            .attributesOfItem(atPath: provider.zshrcURL.path)[.modificationDate] as? Date
        // Sleep a beat to detect accidental rewrite.
        Thread.sleep(forTimeInterval: 0.05)
        try provider.install()
        let mtime2 = try FileManager.default
            .attributesOfItem(atPath: provider.zshrcURL.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2, "install() must not rewrite file with identical content")
    }

    @Test func installRewritesWhenContentsDiffer() throws {
        let (provider, tmp) = try makeTempProvider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "stale content".write(to: provider.zshrcURL, atomically: true, encoding: .utf8)
        try provider.install()
        let written = try String(contentsOf: provider.zshrcURL, encoding: .utf8)
        #expect(written == ShellAutosuggestionsProvider.generateZshrc())
    }

    @Test func installCreatesIntermediateDirectories() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-autosuggest-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("shell", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(
                at: tmp.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        let provider = ShellAutosuggestionsProvider(directory: tmp)
        _ = try provider.install()
        #expect(FileManager.default.fileExists(atPath: provider.zshrcURL.path))
    }

    @Test func uninstallRemovesDirectory() throws {
        let (provider, tmp) = try makeTempProvider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try provider.install()
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        try provider.uninstall()
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test func uninstallOnMissingDirectoryDoesNotThrow() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-autosuggest-\(UUID().uuidString)")
        let provider = ShellAutosuggestionsProvider(directory: tmp)
        // Directory never created — must not throw.
        try provider.uninstall()
    }

    // MARK: - defaultProvider()

    @Test func defaultProviderPointsUnderApplicationSupportPine() {
        let provider = ShellAutosuggestionsProvider.defaultProvider()
        #expect(provider.directory.path.contains("Application Support"))
        #expect(provider.directory.path.contains("Pine"))
        #expect(provider.directory.lastPathComponent == "shell")
    }

    @Test func zshrcURLEndsWithDotZshrc() throws {
        let (provider, tmp) = try makeTempProvider()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(provider.zshrcURL.lastPathComponent == ".zshrc")
    }
}
