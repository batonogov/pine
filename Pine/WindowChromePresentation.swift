//
//  WindowChromePresentation.swift
//  Pine
//
//  The window's system title — identity only, never displayed.
//

import Foundation

/// The string `NSWindow.title` carries for one project window.
///
/// Nothing on the strip displays it: the visible title is hidden permanently
/// (`WindowTitleVisibilityTracker`), the Safari composition — the switcher
/// pill names the project, the branch toolbar button names the checkout,
/// and editor tabs name the open files. The title's only job is the system
/// identity a window cannot live without: the Window menu, Mission Control,
/// and window cycling read `NSWindow.title` even while the title bar hides
/// it, and an empty title would drop the window from all three. Hence the
/// chain — active file, then repository, then "Pine" — kept for the system
/// even though no human reads it in the title bar.
nonisolated struct WindowChromePresentation: Equatable {
    /// Last-resort title. Pine is a brand name and stays untranslated.
    static let fallbackTitle = "Pine"

    /// Native window title. Always non-empty — see the type's docstring.
    let title: String

    init(
        activeFileName: String?,
        repositoryName: String
    ) {
        title = Self.presentable(activeFileName)
            ?? Self.presentable(repositoryName)
            ?? Self.fallbackTitle
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
