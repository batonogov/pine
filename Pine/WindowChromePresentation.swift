//
//  WindowChromePresentation.swift
//  Pine
//
//  Title-bar text for one project window: what the title says, and whether
//  the project switcher repeats it.
//

import Foundation

/// The two pieces of text a project window puts in its title bar, resolved
/// together so the same string never appears twice in one strip.
///
/// The window title carries the active file, matching how Xcode splits the
/// two surfaces: the switcher answers "which project", the title answers
/// "which file". With no editor tab open there is nothing file-shaped to
/// show, so the title falls back to the project — a window must stay
/// identifiable in the Window menu, Mission Control, and window cycling, and
/// an empty title is never an option.
///
/// That fallback is exactly when the switcher would echo the title, and it is
/// not a rare state: a project with no restored session opens straight into a
/// terminal (#1251), so it is the first thing a new project shows. Whenever
/// the two would read identically the switcher drops its text and stays an
/// icon; the name is still one click away and still in the title bar.
///
/// The comparison is on the resolved strings rather than on "is a file open",
/// which keeps an agent worktree readable: its switcher reads
/// `pine — feat/branch` while the title falls back to the repository name
/// `pine`, so the branch — the one thing distinguishing that window — never
/// gets suppressed as a duplicate.
nonisolated struct WindowChromePresentation: Equatable {
    /// Last-resort title. Pine is a brand name and stays untranslated.
    static let fallbackTitle = "Pine"

    /// Native window title.
    let title: String

    /// Text for the toolbar's project switcher, or `nil` when it would repeat
    /// ``title`` and the switcher should render as an icon alone.
    let switcherLabel: String?

    init(
        activeFileName: String?,
        repositoryName: String,
        switcherLabel: String
    ) {
        let resolvedTitle = Self.presentable(activeFileName)
            ?? Self.presentable(repositoryName)
            ?? Self.fallbackTitle
        title = resolvedTitle

        let resolvedLabel = Self.presentable(switcherLabel)
        self.switcherLabel = resolvedLabel == resolvedTitle
            ? nil
            : resolvedLabel
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
