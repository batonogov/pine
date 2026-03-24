//
//  TabNavigationTests.swift
//  PineTests
//
//  Tests for keyboard-driven tab navigation:
//  - selectTab(at:) — Cmd+1/2/3...9
//  - selectNextTab() — Ctrl+Tab
//  - selectPreviousTab() — Ctrl+Shift+Tab
//  - selectLastTab() — Cmd+9
//  - First responder flow on tab switch
//

import Foundation
import Testing

@testable import Pine

@Suite("Tab Navigation Tests")
struct TabNavigationTests {

    // MARK: - Helpers

    private func makeTabManager(count: Int) -> TabManager {
        let tm = TabManager()
        for i in 0..<count {
            let url = URL(fileURLWithPath: "/tmp/file\(i).swift")
            let tab = EditorTab(url: url, content: "// file \(i)", savedContent: "// file \(i)")
            tm.tabs.append(tab)
        }
        if !tm.tabs.isEmpty {
            tm.activeTabID = tm.tabs[0].id
        }
        return tm
    }

    // MARK: - selectTab(at:)

    @Test("selectTab(at:) switches to the tab at the given 0-based index")
    func selectTabAtIndex() {
        let tm = makeTabManager(count: 5)
        tm.selectTab(at: 2)
        #expect(tm.activeTabID == tm.tabs[2].id)
    }

    @Test("selectTab(at:) with index 0 selects the first tab")
    func selectFirstTab() {
        let tm = makeTabManager(count: 3)
        tm.selectTab(at: 2)
        tm.selectTab(at: 0)
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    @Test("selectTab(at:) does nothing when index is out of bounds")
    func selectTabOutOfBounds() {
        let tm = makeTabManager(count: 3)
        let originalID = tm.activeTabID
        tm.selectTab(at: 10)
        #expect(tm.activeTabID == originalID)
    }

    @Test("selectTab(at:) does nothing with negative index")
    func selectTabNegativeIndex() {
        let tm = makeTabManager(count: 3)
        let originalID = tm.activeTabID
        tm.selectTab(at: -1)
        #expect(tm.activeTabID == originalID)
    }

    @Test("selectTab(at:) does nothing when tabs are empty")
    func selectTabEmptyTabs() {
        let tm = TabManager()
        tm.selectTab(at: 0)
        #expect(tm.activeTabID == nil)
    }

    @Test("selectTab(at:) is idempotent when selecting already active tab")
    func selectAlreadyActiveTab() {
        let tm = makeTabManager(count: 3)
        tm.selectTab(at: 0)
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    // MARK: - selectLastTab()

    @Test("selectLastTab() selects the last tab (Cmd+9 behavior)")
    func selectLastTab() {
        let tm = makeTabManager(count: 7)
        tm.selectLastTab()
        #expect(tm.activeTabID == tm.tabs[6].id)
    }

    @Test("selectLastTab() does nothing when tabs are empty")
    func selectLastTabEmpty() {
        let tm = TabManager()
        tm.selectLastTab()
        #expect(tm.activeTabID == nil)
    }

    @Test("selectLastTab() works with a single tab")
    func selectLastTabSingleTab() {
        let tm = makeTabManager(count: 1)
        tm.selectLastTab()
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    // MARK: - selectNextTab()

    @Test("selectNextTab() advances to the next tab")
    func selectNextTab() {
        let tm = makeTabManager(count: 3)
        tm.selectTab(at: 0)
        tm.selectNextTab()
        #expect(tm.activeTabID == tm.tabs[1].id)
    }

    @Test("selectNextTab() wraps around from last to first")
    func selectNextTabWraps() {
        let tm = makeTabManager(count: 3)
        tm.selectTab(at: 2)
        tm.selectNextTab()
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    @Test("selectNextTab() does nothing with single tab")
    func selectNextTabSingle() {
        let tm = makeTabManager(count: 1)
        tm.selectNextTab()
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    @Test("selectNextTab() does nothing when no tabs")
    func selectNextTabEmpty() {
        let tm = TabManager()
        tm.selectNextTab()
        #expect(tm.activeTabID == nil)
    }

    // MARK: - selectPreviousTab()

    @Test("selectPreviousTab() moves to the previous tab")
    func selectPreviousTab() {
        let tm = makeTabManager(count: 3)
        tm.selectTab(at: 1)
        tm.selectPreviousTab()
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    @Test("selectPreviousTab() wraps around from first to last")
    func selectPreviousTabWraps() {
        let tm = makeTabManager(count: 3)
        tm.selectTab(at: 0)
        tm.selectPreviousTab()
        #expect(tm.activeTabID == tm.tabs[2].id)
    }

    @Test("selectPreviousTab() does nothing with single tab")
    func selectPreviousTabSingle() {
        let tm = makeTabManager(count: 1)
        tm.selectPreviousTab()
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    @Test("selectPreviousTab() does nothing when no tabs")
    func selectPreviousTabEmpty() {
        let tm = TabManager()
        tm.selectPreviousTab()
        #expect(tm.activeTabID == nil)
    }

    // MARK: - Sequential navigation

    @Test("Multiple selectNextTab calls cycle through all tabs")
    func cycleThroughAllTabs() {
        let tm = makeTabManager(count: 4)
        guard let startID = tm.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        var visited: [UUID] = [startID]
        for _ in 0..<4 {
            tm.selectNextTab()
            guard let currentID = tm.activeTabID else {
                Issue.record("activeTabID became nil during cycle")
                return
            }
            visited.append(currentID)
        }
        // After 4 next calls on 4 tabs, should be back to start
        #expect(visited.first == visited.last)
        // All tabs should have been visited
        let uniqueVisited = Set(visited)
        #expect(uniqueVisited.count == 4)
    }

    @Test("selectPreviousTab undoes selectNextTab")
    func previousUndoesNext() {
        let tm = makeTabManager(count: 5)
        let originalID = tm.activeTabID
        tm.selectNextTab()
        tm.selectPreviousTab()
        #expect(tm.activeTabID == originalID)
    }

    // MARK: - Edge: activeTabID is nil but tabs exist

    @Test("selectNextTab sets first tab when activeTabID is nil but tabs exist")
    func selectNextWhenNoActive() {
        let tm = makeTabManager(count: 3)
        tm.activeTabID = nil
        tm.selectNextTab()
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    @Test("selectPreviousTab sets last tab when activeTabID is nil but tabs exist")
    func selectPreviousWhenNoActive() {
        let tm = makeTabManager(count: 3)
        tm.activeTabID = nil
        tm.selectPreviousTab()
        #expect(tm.activeTabID == tm.tabs[2].id)
    }
}
