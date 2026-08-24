//
//  WindowRoutingReach.swift
//  Pine
//
//  How far a routing caller can reach for a window that is not on screen
//  (#1507).
//

import Foundation

/// Whether routed work may land in a window that is sitting in the Dock.
///
/// `NSWindow.isVisible` reads `false` while a window is miniaturized —
/// miniaturizing removes the window from the screen list — so an eligibility
/// check written as `isVisible` alone silently refuses every minimized
/// window. Verified on macOS 27.0 (26A5416b): a miniaturized window reports
/// `isVisible == false`, `isMiniaturized == true`, and stays in
/// `NSApp.windows`; an ordered-out window reports `false` for both. The rule
/// below therefore admits a Dock window through `isMiniaturized`, never by
/// weakening the visibility test, so a closed or hidden window remains
/// refused on either macOS version.
///
/// The distinction is not cosmetic: a caller that mutates a window in place
/// — New File, Close Tab — would apply the command invisibly to a window in
/// the Dock, while a caller that restores and focuses its host first shows
/// the user exactly where the work landed. Each caller states which of the
/// two it is.
enum WindowRoutingReach {
    /// The caller acts on the window as it is. A window in the Dock would
    /// receive the command without ever coming back on screen, so it is
    /// refused.
    case onScreenOnly
    /// The caller restores and focuses its host before presenting, so a
    /// window in the Dock is a legitimate destination — it comes back first.
    case onScreenOrDock

    /// Whether a window with these AppKit facts may receive routed work.
    ///
    /// The two flags are read independently rather than assuming AppKit's
    /// coupling holds: `.onScreenOnly` answers "is this window on screen",
    /// so the contradictory pair — visible *and* miniaturized, which macOS 27
    /// never reports — resolves to "in the Dock" and is refused, matching the
    /// explicit `isVisible && !isMiniaturized` test the Welcome lookup used
    /// before this rule existed. `.onScreenOrDock` accepts either flag, so it
    /// admits a Dock window on any macOS that disagrees about `isVisible`.
    func admitsWindow(isVisible: Bool, isMiniaturized: Bool) -> Bool {
        switch self {
        case .onScreenOnly:
            return isVisible && !isMiniaturized
        case .onScreenOrDock:
            return isVisible || isMiniaturized
        }
    }
}
