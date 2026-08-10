//
//  MenuSaveReentrancyTests.swift
//  PineTests
//
//  Regression tests for the macOS 26 exclusivity abort (SIGABRT) triggered by
//  the File menu Save / Save All / Save As commands when format-on-save (or
//  any save transform: strip-trailing-whitespace, insert-final-newline)
//  changes the buffer content.
//
//  Root cause: the menu command runs `activeTabManager.saveActiveTab()`
//  synchronously inside the `ButtonAction` callstack. When format-on-save
//  reformats the content, `TabPersistence.saveTabContent` mutates
//  `@Observable TabManager.tabs` (`content`, `cachedHighlightResult`,
//  `recomputeContentCaches()`) AND synchronously posts `.tabReloadedFromDisk`
//  — all inside the button-action callstack. Mutating `@Observable` there
//  forces a synchronous SwiftUI body re-evaluation that collides with the
//  button-action's exclusive access to SwiftUI storage →
//  `_swift_reportExclusivityConflict` → `abort()`.
//
//  Smart-list continuation is not itself the cause; it produces Markdown list
//  markers / trailing whitespace that the save transforms (strip-whitespace /
//  insert-final-newline / formatter) then modify, so `contentChanged == true`
//  on save — which is what gates the synchronous mutation path.
//
//  This is the same class of bug as #1047 / #1051 / #1056 (fold observer) on
//  the menu-save path. The fix defers the save (disk write + @Observable
//  mutation + notification) to the next runloop via
//  `ProjectManager.saveActiveTabFromMenu()` / `saveAllTabsFromMenu()`, so the
//  button-action callstack unwinds first. Interactive saves then prepare their
//  transformed content asynchronously before the revision-fenced commit.
//
//  These tests pin the contract via the observable side effect of the deferral:
//  the file must NOT be rewritten synchronously when the menu-save method is
//  invoked, but MUST complete after the deferred async preparation. Removing the
//  `DispatchQueue.main.async` from `performMenuSave` turns the tests red —
//  verified by regression injection.
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct MenuSaveReentrancyTests {

    // MARK: - Harness

    private func makeTempFile(content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("menu-save-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func readDisk(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func waitUntilDiskChanges(
        _ url: URL,
        from original: String
    ) async throws {
        for _ in 0..<500 {
            if readDisk(url) != original { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(readDisk(url) != original)
    }

    // MARK: - saveActiveTabFromMenu defers the disk write (#1058)

    @Test("saveActiveTabFromMenu does not rewrite the file synchronously when format-on-save changes content")
    func saveActiveTabFromMenuNotSynchronous() async throws {
        let pm = ProjectManager()
        let settings = EditorSettings(defaults: makeIsolatedDefaults())
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        pm.primaryTabManager.editorSettings = settings
        pm.primaryTabManager.fileFormatters = .default

        // Unformatted JSON — the pure-Swift JSONFileFormatter will pretty-print
        // it on save, so `contentChanged == true` and the synchronous mutation
        // path (the crash path) executes once the save actually runs.
        let unformatted = "{\"a\":1,\"b\":2}"
        let url = try makeTempFile(content: unformatted, ext: "json")
        defer { try? FileManager.default.removeItem(at: url) }

        pm.primaryTabManager.openTab(url: url)
        let originalOnDisk = readDisk(url)

        // Invoke the menu-save entry point — as the File menu ButtonAction does.
        pm.saveActiveTabFromMenu()

        // Contract #1 (the crash fix): the save must NOT have run
        // synchronously. If it did, the @Observable mutation executed inside
        // the (would-be) button-action callstack and the fix has regressed.
        // We observe this via the file-on-disk side effect: format-on-save
        // rewrites the file, so a synchronous save would have changed it.
        #expect(readDisk(url) == originalOnDisk,
                "saveActiveTabFromMenu must not perform the save synchronously (the reentrancy that triggers the exclusivity abort)")

        // Contract #2: the deferred async save must eventually rewrite the
        // file (format-on-save changed the content).
        try await waitUntilDiskChanges(url, from: originalOnDisk)
        #expect(readDisk(url) != originalOnDisk,
                "saveActiveTabFromMenu must complete its deferred async save")
        #expect(readDisk(url).contains("\n"),
                "deferred format-on-save must have pretty-printed the JSON")
    }

    // MARK: - saveAllTabsFromMenu defers too (#1058)

    @Test("saveAllTabsFromMenu does not rewrite files synchronously")
    func saveAllTabsFromMenuNotSynchronous() async throws {
        let pm = ProjectManager()
        let settings = EditorSettings(defaults: makeIsolatedDefaults())
        settings.formatOnSave = true                  // changes content → contentChanged
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        pm.primaryTabManager.editorSettings = settings
        pm.primaryTabManager.fileFormatters = .default

        let onDisk = "{\"a\":1}"
        let url = try makeTempFile(content: onDisk, ext: "json")
        defer { try? FileManager.default.removeItem(at: url) }

        pm.primaryTabManager.openTab(url: url)
        // saveAllTabs() only persists dirty tabs — set a different (still
        // unformatted) content so the tab is dirty AND format-on-save will
        // rewrite the file. saveActiveTab writes unconditionally; Save All
        // does not, so the dirty setup is required here.
        pm.primaryTabManager.updateContent("{\"a\":1,\"b\":2,\"c\":3}")
        // Explicit precondition: saveAllTabs only persists dirty tabs, so the
        // deferred save is observable only when this holds. Asserting it here
        // fails with a clear message if isDirty/updateContent semantics drift.
        #expect(pm.primaryTabManager.activeTab?.isDirty == true,
                "precondition: tab must be dirty for saveAllTabs to persist it")
        let originalOnDisk = readDisk(url)

        pm.saveAllTabsFromMenu()

        #expect(readDisk(url) == originalOnDisk,
                "saveAllTabsFromMenu must not perform the save synchronously")

        try await waitUntilDiskChanges(url, from: originalOnDisk)
        #expect(readDisk(url) != originalOnDisk,
                "saveAllTabsFromMenu must complete its deferred async save")
        #expect(readDisk(url).contains("\n"),
                "deferred format-on-save must have pretty-printed the JSON")
    }

    // MARK: - Legacy synchronous primitive

    @Test("direct saveActiveTab() remains synchronous for legacy callers")
    func directSaveIsSynchronous() throws {
        // Keep the legacy pure-formatter helper synchronous for focused tests
        // and noninteractive callers. Production Save, Save All, Save As, and
        // auto-save use the revision-fenced async path.
        let pm = ProjectManager()
        let settings = EditorSettings(defaults: makeIsolatedDefaults())
        settings.formatOnSave = true
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        pm.primaryTabManager.editorSettings = settings
        pm.primaryTabManager.fileFormatters = .default

        let unformatted = "{\"a\":1}"
        let url = try makeTempFile(content: unformatted, ext: "json")
        defer { try? FileManager.default.removeItem(at: url) }

        pm.primaryTabManager.openTab(url: url)

        // Direct synchronous call (the non-menu path) — must rewrite now.
        _ = pm.activeTabManager.saveActiveTab()

        #expect(readDisk(url) != unformatted,
                "direct saveActiveTab() must save synchronously (menu-only deferral)")
    }

    // MARK: - Private helpers

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "MenuSaveReentrancyTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
