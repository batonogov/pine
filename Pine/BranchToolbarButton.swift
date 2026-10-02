//
//  BranchToolbarButton.swift
//  Pine
//
//  The branch indicator as a first-class toolbar control, replacing the
//  navigation subtitle it used to live in.
//

import SwiftUI

/// Shows the current branch next to the project pill and opens the branch
/// switcher. Born of the permanently hidden window title: hiding the title
/// removes the whole native title block, subtitle included (see
/// ``WindowTitleVisibilityTracker``), so the branch needed a new home —
/// and a real button makes the affordance XCUITest- and VoiceOver-reachable,
/// which the AppKit gesture recognizer on the subtitle text field
/// (`BranchSubtitleClickHandler`, deleted) never was. The switcher itself
/// opens as the same sheet the Git menu uses.
struct BranchToolbarButton: View {
    /// Display text, e.g. "main ▾", from `ContentView.branchSubtitle`.
    let title: String
    /// Bare branch name for the VoiceOver label, without the "▾" affordance
    /// marker.
    let branchName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // No explicit `buttonStyle`: the toolbar's own style gives the item
        // its hover chrome and standard metric, the same contract the other
        // toolbar controls rely on.
        .help(Strings.menuSwitchBranch)
        .accessibilityLabel(Text(branchName))
        .accessibilityIdentifier(AccessibilityID.branchSwitcherButton)
    }
}
