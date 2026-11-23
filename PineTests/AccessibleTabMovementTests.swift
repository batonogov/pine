import Foundation
import Testing
@testable import Pine

@Suite("Keyboard and VoiceOver Tab Movement")
@MainActor
struct AccessibleTabMovementTests {
    @Test("Editor leading and trailing moves preserve pinned boundary")
    func editorReorderAndPinnedBoundary() throws {
        let paneManager = PaneManager()
        let paneID = paneManager.activePaneID
        let manager = try #require(paneManager.tabManager(for: paneID))
        let urls = ["a.swift", "b.swift", "c.swift"].map {
            URL(fileURLWithPath: "/project/\($0)")
        }
        manager.tabs = urls.map { EditorTab(url: $0) }
        manager.activeTabID = manager.tabs[1].id
        manager.togglePin(id: manager.tabs[0].id)
        let activeID = try #require(manager.activeTabID)

        #expect(!paneManager.canMoveActiveTab(.leading))
        #expect(!paneManager.moveActiveTab(.leading))
        #expect(manager.tabs.map(\.url) == urls)

        #expect(paneManager.canMoveActiveTab(.trailing))
        #expect(paneManager.moveActiveTab(.trailing))
        #expect(manager.tabs.map(\.url) == [urls[0], urls[2], urls[1]])
        #expect(manager.activeTabID == activeID)
        #expect(manager.pendingFocusTabID == activeID)
    }

    @Test("Terminal tabs reorder in their single adjacent strip")
    func terminalReorder() throws {
        let paneManager = PaneManager()
        let terminalPane = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state = try #require(paneManager.terminalState(for: terminalPane))
        let original = try #require(state.terminalTabs.first)
        let extra = state.addTab(workingDirectory: nil)
        state.activeTerminalID = original.id
        paneManager.activePaneID = terminalPane

        #expect(paneManager.moveActiveTab(.trailing))
        #expect(state.terminalTabs.map(\.id) == [extra.id, original.id])
        #expect(state.terminalTabs.first?.id == extra.id)
        #expect(state.pendingFocusTabID == original.id)
    }
}
