//
//  TabPinningTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("TabPinning Tests")
@MainActor
struct TabPinningTests {

    private func makeTabs(_ names: [String]) -> [EditorTab] {
        names.map { EditorTab(url: URL(fileURLWithPath: "/tmp/\($0)"), content: "", savedContent: "") }
    }

    @Test("togglePin pins tab and moves to left")
    func togglePinMovesLeft() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        TabPinning.togglePin(id: tabs[2].id, in: &tabs)
        #expect(tabs[0].isPinned == true)
        #expect(tabs[0].url.lastPathComponent == "c.swift")
        #expect(tabs[1].isPinned == false)
    }

    @Test("togglePin unpins tab and moves to right of pinned group")
    func togglePinUnpinsMovesRight() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        tabs[0].isPinned = true
        TabPinning.togglePin(id: tabs[0].id, in: &tabs)
        #expect(tabs[0].isPinned == false)
        // Should be at position 0 (after any remaining pinned — there are none)
    }

    @Test("pinnedTabCount returns correct count")
    func pinnedTabCount() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        #expect(TabPinning.pinnedTabCount(in: tabs) == 0)
        tabs[0].isPinned = true
        tabs[2].isPinned = true
        #expect(TabPinning.pinnedTabCount(in: tabs) == 2)
    }

    @Test("restorePinnedState sets isPinned and sorts")
    func restorePinnedState() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        let paths: Set<String> = ["/tmp/c.swift", "/tmp/a.swift"]
        TabPinning.restorePinnedState(pinnedPaths: paths, in: &tabs)
        #expect(tabs[0].isPinned == true)
        #expect(tabs[1].isPinned == true)
        #expect(tabs[2].isPinned == false)
        // Pinned should come first: a.swift, c.swift, then b.swift
        #expect(tabs[0].url.lastPathComponent == "a.swift")
        #expect(tabs[1].url.lastPathComponent == "c.swift")
        #expect(tabs[2].url.lastPathComponent == "b.swift")
    }

    @Test("togglePin is no-op for unknown ID")
    func togglePinUnknownID() {
        var tabs = makeTabs(["a.swift"])
        let original = tabs
        TabPinning.togglePin(id: UUID(), in: &tabs)
        #expect(tabs[0].id == original[0].id)
        #expect(tabs[0].isPinned == original[0].isPinned)
    }

    @Test("multiple pins preserve relative order within groups")
    func multiplePinOrder() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift", "d.swift"])
        // Pin d (at index 3) → moves to index 0: [d, a, b, c]
        let dID = tabs[3].id
        TabPinning.togglePin(id: dID, in: &tabs)
        // Now b is at index 2. Pin b → moves after d: [d, b, a, c]
        let bID = tabs[2].id
        TabPinning.togglePin(id: bID, in: &tabs)
        let pinnedNames = tabs.filter(\.isPinned).map(\.url.lastPathComponent)
        let unpinnedNames = tabs.filter { !$0.isPinned }.map(\.url.lastPathComponent)
        #expect(pinnedNames == ["d.swift", "b.swift"])
        #expect(unpinnedNames == ["a.swift", "c.swift"])
    }
}
