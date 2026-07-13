//
//  TerminalLinkOpener.swift
//  Pine
//
//  Pure dispatcher for OSC 8 terminal-hyperlink activation (#1114).
//
//  SwiftTerm parses explicit OSC 8 sequences (`ESC ] 8 ;; <uri> ESC \`) and
//  implicit URL detection itself; it then calls the terminal delegate's
//  `requestOpenLink(source:link:params:)`. Pine's only job is to decide —
//  safely — what to do with the URI. A terminal renders untrusted program
//  output, so the scheme/host dispatch is security-critical and extracted
//  here as a pure function so it is unit-testable in isolation.
//
//  Security boundary (mirrors agterm): a `file://` link may point at a
//  `.app`/`.command` bundle a hostile program sneaked into its output.
//  "Reveal in Finder" (`NSWorkspace.activateFileViewerSelecting`) selects
//  the file WITHOUT launching it; "open" would execute it. So `file://`
//  always reveals, never opens. A `file://` link naming a foreign host is
//  ignored entirely — a stray link must not trigger a Finder network mount.
//

import Foundation

/// The action Pine takes when the user activates an OSC 8 terminal
/// hyperlink. A value type so the decision is testable without touching
/// `NSWorkspace` or the filesystem.
enum TerminalLinkAction: Equatable {
    /// `file://` link — reveal the file in Finder without launching it.
    /// `NSWorkspace.activateFileViewerSelecting` selects the entry but never
    /// runs it, which is the safe default for untrusted terminal output
    /// (a link may point at a `.app` / `.command` bundle).
    case revealInFinder(URL)
    /// `http(s)` / `mailto` link — open in the system handler (browser /
    /// mail client) via `NSWorkspace.open`.
    case openExternally(URL)
}

/// Pure dispatcher from a link URI string to a ``TerminalLinkAction``.
///
/// Returns `nil` for anything Pine should ignore: unparseable URIs, URIs
/// without a scheme, unsupported schemes (`ftp`, `ssh`, …), and `file://`
/// URIs that name a foreign host (to avoid triggering a Finder network
/// mount from untrusted output).
enum TerminalLinkOpener {

    /// Resolves the action for a link URI, or `nil` to ignore.
    ///
    /// - Parameter urlString: the raw URI as reported by SwiftTerm
    ///   (`requestOpenLink(source:link:params:)`'s `link`).
    static func action(for urlString: String) -> TerminalLinkAction? {
        guard let url = URL(string: urlString) else { return nil }
        guard let scheme = url.scheme?.lowercased() else { return nil }

        switch scheme {
        case "file":
            // Ignore `file://` links naming a foreign host: a stray link in
            // untrusted output must not trigger a Finder network mount
            // (agterm's security boundary). Empty / `localhost` hosts are
            // local and safe.
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
                return nil
            }
            return .revealInFinder(url)
        case "http", "https", "mailto":
            return .openExternally(url)
        default:
            // Unsupported scheme (ftp, ssh, git, …) — ignore.
            return nil
        }
    }
}
