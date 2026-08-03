//
//  PineAppMenuCommandsTests.swift
//  PineTests
//
//  Smoke tests for the extracted menu command group and notification names
//  (refactor of PineApp.swift in #756).
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct PineAppMenuCommandsTests {
    /// Smoke-test: instantiate the Commands struct with inert dependencies
    /// and ensure it does not crash when `focusedProject` is `nil`. Also
    /// verify that accessing `body` evaluates without throwing — this
    /// exercises the generic expansion of every `CommandGroup`/`CommandMenu`
    /// and is the cheapest way to catch typos or mis-wired `@FocusedValue`
    /// access paths after future edits. The inert updater seam is deliberate:
    /// constructing a temporary AppDelegate here would start a second real
    /// Sparkle runtime inside Pine's already-running test host.
    @Test
    func instantiationWithNilFocusedProjectDoesNotCrash() {
        let commands = PineAppMenuCommands(
            checkForUpdatesViewModel: CheckForUpdatesViewModel(
                canCheckForUpdates: false,
                checkForUpdatesAction: {}
            ),
            toggleQuickTerminal: {},
            recentProjects: { [] },
            showAgentInbox: {}
        )
        // `body` is `some Commands` — we can't introspect it, but forcing
        // evaluation verifies the view-builder closure compiles and runs
        // without preconditions failing for the default (no focused project)
        // state.
        _ = commands.body
        #expect(Bool(true))
    }

    /// Sanity-check that the notification name extension defines a meaningful
    /// set of unique, non-empty raw values. Guards against accidental
    /// duplicates after future edits to `PineAppNotifications.swift`.
    @Test
    func notificationNamesAreUniqueAndNonEmpty() {
        let names: [Notification.Name] = [
            .newFile, .openFile, .openRecentProject, .showAgentInbox,
            .clearRecentProjects, .openFolder,
            .closeTab, .closeWindow, .goToLine,
            .findInFile, .findAndReplace, .findNext, .findPrevious,
            .useSelectionForFind, .toggleWordWrap, .toggleComment,
            .showProjectSearch, .navigateChange, .foldCode,
            .findInTerminal, .showQuickOpen, .showSymbolNavigator,
            .symbolNavigate, .sendToTerminal, .sendTextToTerminal,
            .revealInSidebar, .inlineDiffAction, .tabReloadedFromDisk,
            .showBranchSwitcher, .refreshLineDiffs, .fileRenamed, .fileDeleted
        ]
        let raws = names.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "Notification names must be unique")
        #expect(raws.allSatisfy { !$0.isEmpty }, "Notification names must be non-empty")
    }

    @Test
    func branchSwitchShortcutIsDocumentedInReadme() throws {
        let readmeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let content = try String(contentsOf: readmeURL, encoding: .utf8)
        #expect(content.contains("| `Cmd+Shift+B` | Switch branch |"))
    }

    @Test
    func branchSwitcherNotificationScopeMatchesTargetProjectOrKeyWindow() {
        let currentProject = ProjectManager()
        let otherProject = ProjectManager()

        #expect(ContentView.shouldPresentBranchSwitcher(
            notificationObject: currentProject,
            currentProject: currentProject,
            isKeyWindow: false,
            isGitRepository: true
        ))
        #expect(!ContentView.shouldPresentBranchSwitcher(
            notificationObject: otherProject,
            currentProject: currentProject,
            isKeyWindow: true,
            isGitRepository: true
        ))
        #expect(ContentView.shouldPresentBranchSwitcher(
            notificationObject: nil,
            currentProject: currentProject,
            isKeyWindow: true,
            isGitRepository: true
        ))
        #expect(!ContentView.shouldPresentBranchSwitcher(
            notificationObject: nil,
            currentProject: currentProject,
            isKeyWindow: false,
            isGitRepository: true
        ))
        #expect(!ContentView.shouldPresentBranchSwitcher(
            notificationObject: currentProject,
            currentProject: currentProject,
            isKeyWindow: true,
            isGitRepository: false
        ))
        #expect(!ContentView.shouldPresentBranchSwitcher(
            notificationObject: "unexpected",
            currentProject: currentProject,
            isKeyWindow: true,
            isGitRepository: true
        ))
    }
}
