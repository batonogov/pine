//
//  PreviewTabTests.swift
//  PineTests
//
//  Tests for transient preview tabs and their promotion triggers (issue #1168).
//  A transient preview is replaced (not stacked) when another file is opened as
//  a preview; it is promoted to a permanent tab on edit, pin, explicit open,
//  or move.
//

import Foundation
import Testing

@testable import Pine

@Suite("Transient Preview Tab Tests")
@MainActor
struct PreviewTabTests {

    // MARK: - Helpers

    /// Creates a TabManager with the given number of tabs, each backed by a
    /// distinct file URL so duplicate-URL rejection does not interfere.
    private func makeTabManager(count: Int) -> TabManager {
        let tm = TabManager()
        for i in 0..<count {
            let url = URL(fileURLWithPath: "/tmp/preview/file\(i).swift")
            let tab = EditorTab(url: url, content: "// \(i)", savedContent: "// \(i)")
            tm.tabs.append(tab)
        }
        if !tm.tabs.isEmpty { tm.activeTabID = tm.tabs[0].id }
        return tm
    }

    private func makePreviewURL(_ suffix: String) -> URL {
        URL(fileURLWithPath: "/tmp/preview/peek_\(suffix).swift")
    }

    // MARK: - Replacement rules

    @Test("openTabAsPreview marks the new tab as transient")
    func openAsPreviewMarksTransient() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let previewTab = try #require(tm.tabs.last)
        #expect(previewTab.isTransientPreview == true)
        #expect(tm.activeTabID == previewTab.id)
    }

    @Test("openTabAsPreview replaces an existing un-promoted transient preview")
    func previewReplacesUnpromotedPreview() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let firstPreviewID = try #require(tm.tabs.last).id
        #expect(tm.tabs.count == 2)

        tm.openTabAsPreview(url: makePreviewURL("b"))
        // The first preview is replaced in place, not stacked.
        #expect(tm.tabs.count == 2)
        #expect(tm.tabs.contains(where: { $0.id == firstPreviewID }) == false)
        let newPreview = try #require(tm.tabs.last)
        #expect(newPreview.isTransientPreview == true)
        #expect(newPreview.url.lastPathComponent == "peek_b.swift")
    }

    @Test("A preview is replaced even after a permanent tab becomes active")
    func inactivePreviewIsStillReplaced() throws {
        let tm = makeTabManager(count: 1)
        let permanentID = tm.tabs[0].id
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let firstPreviewID = try #require(tm.activeTab).id

        tm.activeTabID = permanentID
        tm.openTabAsPreview(url: makePreviewURL("b"))

        #expect(tm.tabs.count == 2)
        #expect(tm.tabs.contains(where: { $0.id == firstPreviewID }) == false)
        #expect(tm.tabs.filter(\.isTransientPreview).count == 1)
        #expect(try #require(tm.activeTab).url.lastPathComponent == "peek_b.swift")
    }

    @Test("openTabAsPreview appends when active tab is a permanent tab")
    func previewAppendsAfterPermanent() throws {
        let tm = makeTabManager(count: 2)
        // Both existing tabs are permanent (not transient).
        tm.openTabAsPreview(url: makePreviewURL("a"))
        // A new preview is appended; existing permanent tabs are untouched.
        #expect(tm.tabs.count == 3)
        #expect(try #require(tm.tabs.last).isTransientPreview == true)
    }

    @Test("openTabAsPreview activates an existing permanent tab instead of duplicating")
    func previewActivatesExistingPermanent() {
        let tm = makeTabManager(count: 1)
        let permanentURL = tm.tabs[0].url
        tm.openTabAsPreview(url: permanentURL)
        // No duplicate tab created; existing permanent tab activated.
        #expect(tm.tabs.count == 1)
        #expect(tm.tabs[0].isTransientPreview == false)
    }

    // MARK: - Promotion trigger: edit

    @Test("Editing a transient preview promotes it to permanent")
    func editPromotesTransientPreview() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let active = try #require(tm.activeTab)
        #expect(active.isTransientPreview == true)

        tm.updateContent("// edited")
        let promoted = try #require(tm.activeTab)
        #expect(promoted.isTransientPreview == false)
        #expect(promoted.content == "// edited")
    }

    // MARK: - Promotion trigger: pin

    @Test("Pinning a transient preview promotes it to permanent")
    func pinPromotesTransientPreview() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let previewID = try #require(tm.activeTab).id

        tm.togglePin(id: previewID)
        let pinnedTab = try #require(tm.tabs.first(where: { $0.id == previewID }))
        #expect(pinnedTab.isPinned == true)
        #expect(pinnedTab.isTransientPreview == false)
    }

    // MARK: - Promotion trigger: explicit open

    @Test("promoteTransientPreview clears the transient flag")
    func explicitPromotionClearsFlag() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let previewID = try #require(tm.activeTab).id

        // Simulates an explicit open (double-click / menu "Open").
        tm.promoteTransientPreview(tabID: previewID)
        let tab = try #require(tm.tabs.first(where: { $0.id == previewID }))
        #expect(tab.isTransientPreview == false)
    }

    @Test("Opening a preview normally promotes the existing tab")
    func normalOpenPromotesPreview() throws {
        let tm = makeTabManager(count: 1)
        let previewURL = makePreviewURL("a")
        tm.openTabAsPreview(url: previewURL)
        let previewID = try #require(tm.activeTab).id

        tm.openTab(url: previewURL)

        #expect(tm.tabs.count == 2)
        let promoted = try #require(tm.tabs.first(where: { $0.id == previewID }))
        #expect(promoted.isTransientPreview == false)
    }

    @Test("promoteTransientPreview is a no-op for a permanent tab")
    func promotePermanentIsNoOp() {
        let tm = makeTabManager(count: 1)
        let permanentID = tm.tabs[0].id
        tm.promoteTransientPreview(tabID: permanentID)
        #expect(tm.tabs[0].isTransientPreview == false)
    }

    @Test("promoteActiveTransientPreview promotes only the active tab")
    func promoteActiveOnly() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        tm.openTabAsPreview(url: makePreviewURL("b"))
        // Now there are: file0 (permanent) + peek_b (transient active).
        let transientID = try #require(tm.activeTab).id

        tm.promoteActiveTransientPreview()
        let tab = try #require(tm.tabs.first(where: { $0.id == transientID }))
        #expect(tab.isTransientPreview == false)
    }

    // MARK: - Promotion trigger: move (extract)

    @Test("Extracting a transient preview promotes it before transfer")
    func extractPromotesTransientPreview() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        let previewID = try #require(tm.activeTab).id

        let extraction = tm.extractTab(id: previewID)
        let extracted = try #require(extraction)
        // The extracted tab is no longer transient.
        #expect(extracted.tab.isTransientPreview == false)
    }

    @Test("A promoted preview is not replaced by a subsequent preview open")
    func promotedPreviewSurvivesNextPreviewOpen() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        // Promote via edit.
        tm.updateContent("// promoted")
        let promotedID = try #require(tm.activeTab).id
        #expect(try #require(tm.activeTab).isTransientPreview == false)

        // Open another preview — the promoted tab must survive.
        tm.openTabAsPreview(url: makePreviewURL("b"))
        #expect(tm.tabs.contains(where: { $0.id == promotedID }) == true)
        #expect(try #require(tm.tabs.last).isTransientPreview == true)
        #expect(tm.tabs.count == 3)
    }

    // MARK: - isDirty interaction

    @Test("A transient preview is not dirty until edited")
    func transientPreviewNotDirty() throws {
        let tm = makeTabManager(count: 1)
        tm.openTabAsPreview(url: makePreviewURL("a"))
        #expect(try #require(tm.activeTab).isDirty == false)
        // Edit promotes and makes it dirty.
        tm.updateContent("// changed")
        #expect(try #require(tm.activeTab).isDirty == true)
        #expect(try #require(tm.activeTab).isTransientPreview == false)
    }
}
