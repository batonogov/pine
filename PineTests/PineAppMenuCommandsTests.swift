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

struct PineAppMenuCommandsTests {
    /// Sanity-check that the notification name extension defines a meaningful
    /// set of unique, non-empty raw values. Guards against accidental
    /// duplicates after future edits to `PineAppNotifications.swift`.
    @Test
    func notificationNamesAreUniqueAndNonEmpty() {
        let names: [Notification.Name] = [
            .openFolder, .closeTab, .switchBranch, .goToLine,
            .findInFile, .findAndReplace, .findNext, .findPrevious,
            .useSelectionForFind, .toggleWordWrap, .toggleComment,
            .showProjectSearch, .navigateChange, .foldCode,
            .findInTerminal, .showQuickOpen, .showSymbolNavigator,
            .symbolNavigate, .sendToTerminal, .sendTextToTerminal,
            .revealInSidebar, .inlineDiffAction, .tabReloadedFromDisk,
            .refreshLineDiffs, .fileRenamed, .fileDeleted
        ]
        let raws = names.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "Notification names must be unique")
        #expect(raws.allSatisfy { !$0.isEmpty }, "Notification names must be non-empty")
    }
}
