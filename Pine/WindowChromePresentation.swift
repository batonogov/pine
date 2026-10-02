//
//  WindowChromePresentation.swift
//  Pine
//
//  Title-bar text for one project window.
//

import Foundation

/// What a project window's title bar says, and whether it says anything at
/// all.
///
/// The switcher pill always names the project — like Safari's tab-group
/// picker, it is the one place carrying the project's identity. The title
/// therefore carries only what the pill does not say: the active file, the
/// Xcode-style split. With no editor tab open the *visible* title is empty
/// rather than repeating the pill (``showsTitle`` is `false`).
///
/// The title string itself never empties, though: it falls back to the
/// repository name and finally to "Pine", because `NSWindow.title` is the
/// window's identity in the Window menu, Mission Control, and window
/// cycling. The split is resolved the AppKit way — the title stays set and
/// `NSWindow.titleVisibility` hides it — so system surfaces keep a name
/// while the title bar shows only what adds information.
nonisolated struct WindowChromePresentation: Equatable {
    /// Last-resort title. Pine is a brand name and stays untranslated.
    static let fallbackTitle = "Pine"

    /// Native window title. Always non-empty — see the type's docstring for
    /// why the string outlives its visibility.
    let title: String

    /// Whether the title text should be visible in the title bar. `false`
    /// exactly when no file is open and the title fell back to the project
    /// the switcher pill already names.
    let showsTitle: Bool

    init(
        activeFileName: String?,
        repositoryName: String
    ) {
        let resolvedFile = Self.presentable(activeFileName)
        title = resolvedFile
            ?? Self.presentable(repositoryName)
            ?? Self.fallbackTitle
        showsTitle = resolvedFile != nil
    }

    /// A candidate is presentable when it survives trimming and is not a bare
    /// path separator. `URL.lastPathComponent` returns "/" for the filesystem
    /// root, and a lone slash reads as a glitch rather than a window name.
    private static func presentable(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return nil }
        return trimmed
    }
}
