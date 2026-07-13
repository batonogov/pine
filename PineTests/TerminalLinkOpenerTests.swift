//
//  TerminalLinkOpenerTests.swift
//  PineTests
//
//  Tests for the OSC 8 hyperlink dispatcher (#1114). Pins the
//  security-critical scheme/host dispatch without touching NSWorkspace.
//

import Testing
import Foundation
@testable import Pine

@Suite("Terminal Link Opener Tests")
struct TerminalLinkOpenerTests {

    /// Builds a `URL` from a known-good test constant. Force-unwrapping is
    /// safe here — the inputs are literals — but SwiftLint flags it, so the
    /// helper centralises the single `!` behind a disable directive.
    private func url(_ s: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: s)!
    }

    // MARK: - file:// → Reveal in Finder (never launch)

    @Test("file:// with empty host reveals in Finder")
    func fileEmptyHostReveals() {
        let action = TerminalLinkOpener.action(for: "file:///Users/fedor/notes.txt")
        #expect(action == .revealInFinder(url("file:///Users/fedor/notes.txt")))
    }

    @Test("file:// with localhost host reveals in Finder")
    func fileLocalhostReveals() {
        let action = TerminalLinkOpener.action(for: "file://localhost/Users/fedor/notes.txt")
        #expect(action == .revealInFinder(url("file://localhost/Users/fedor/notes.txt")))
    }

    @Test("file:// pointing at a .app bundle still reveals (never launches)")
    func fileAppBundleRevealsNotLaunches() {
        // The whole point of Reveal-in-Finder: even a hostile link to a
        // .app bundle must NOT produce an .openExternally action — it would
        // launch the bundle. Reveal selects it in Finder safely.
        let action = TerminalLinkOpener.action(for: "file:///Applications/Malware.app")
        #expect(action == .revealInFinder(url("file:///Applications/Malware.app")))
    }

    @Test("file:// with a foreign host is ignored (no Finder network mount)")
    func fileForeignHostIgnored() {
        // A stray file:// link in untrusted output naming a remote host
        // must not trigger a Finder network mount (agterm's boundary).
        #expect(TerminalLinkOpener.action(for: "file://fileserver.example.com/share/secret") == nil)
        #expect(TerminalLinkOpener.action(for: "file://192.168.1.5/data") == nil)
    }

    // MARK: - http(s) / mailto → open externally

    @Test("http and https open externally")
    func httpOpensExternally() {
        let https = "https://github.com/batonogov/pine/issues/1114"
        let http = "http://example.com"
        #expect(TerminalLinkOpener.action(for: https) == .openExternally(url(https)))
        #expect(TerminalLinkOpener.action(for: http) == .openExternally(url(http)))
    }

    @Test("mailto opens externally")
    func mailtoOpensExternally() {
        #expect(TerminalLinkOpener.action(for: "mailto:user@example.com") == .openExternally(url("mailto:user@example.com")))
    }

    // MARK: - Ignored

    @Test("unsupported schemes are ignored")
    func unsupportedSchemesIgnored() {
        #expect(TerminalLinkOpener.action(for: "ftp://example.com/file") == nil)
        #expect(TerminalLinkOpener.action(for: "ssh://user@host") == nil)
        #expect(TerminalLinkOpener.action(for: "git://github.com/repo.git") == nil)
        #expect(TerminalLinkOpener.action(for: "slack://channel") == nil)
    }

    @Test("schemeless and unparseable URIs are ignored")
    func schemelessIgnored() {
        #expect(TerminalLinkOpener.action(for: "/Users/fedor/notes.txt") == nil)
        #expect(TerminalLinkOpener.action(for: "just some text") == nil)
        #expect(TerminalLinkOpener.action(for: "") == nil)
    }

    @Test("scheme is matched case-insensitively")
    func schemeCaseInsensitive() {
        #expect(TerminalLinkOpener.action(for: "FILE:///Users/fedor/notes.txt") == .revealInFinder(url("FILE:///Users/fedor/notes.txt")))
        #expect(TerminalLinkOpener.action(for: "HTTPS://example.com") == .openExternally(url("HTTPS://example.com")))
    }
}
