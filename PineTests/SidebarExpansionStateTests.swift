//
//  SidebarExpansionStateTests.swift
//  PineTests
//
//  Tests for sidebar folder expansion state (#739).
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct SidebarExpansionStateTests {

    // MARK: - Helpers

    /// Creates a temporary directory with the given subfolder structure and returns the root URL.
    /// `subdirs` are paths relative to the root, e.g. ["a", "a/b", "c"].
    private func makeTempTree(_ subdirs: [String]) throws -> URL {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory()
        ).appendingPathComponent("pine-sidebar-expansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in subdirs {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    // MARK: - toggle / set / isExpanded

    @Test func newStateIsEmpty() {
        let state = SidebarExpansionState()
        #expect(state.expandedURLs.isEmpty)
        #expect(!state.isExpanded(URL(fileURLWithPath: "/tmp/anything")))
    }

    @Test func toggleExpandsThenCollapses() {
        let state = SidebarExpansionState()
        let url = URL(fileURLWithPath: "/tmp/folder")
        #expect(state.toggle(url) == true)
        #expect(state.isExpanded(url))
        #expect(state.toggle(url) == false)
        #expect(!state.isExpanded(url))
    }

    @Test func setExpandedTrueAndFalse() {
        let state = SidebarExpansionState()
        let url = URL(fileURLWithPath: "/tmp/folder")
        state.setExpanded(url, true)
        #expect(state.isExpanded(url))
        state.setExpanded(url, false)
        #expect(!state.isExpanded(url))
    }

    @Test func setExpandedFalseOnUnknownIsNoOp() {
        let state = SidebarExpansionState()
        let url = URL(fileURLWithPath: "/tmp/never-added")
        state.setExpanded(url, false)
        #expect(state.expandedURLs.isEmpty)
    }

    @Test func multipleFoldersTrackedIndependently() {
        let state = SidebarExpansionState()
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        state.toggle(a)
        state.toggle(b)
        #expect(state.isExpanded(a))
        #expect(state.isExpanded(b))
        state.toggle(a)
        #expect(!state.isExpanded(a))
        #expect(state.isExpanded(b))
    }

    @Test func collapseAllRemovesEverything() {
        let state = SidebarExpansionState()
        state.toggle(URL(fileURLWithPath: "/tmp/a"))
        state.toggle(URL(fileURLWithPath: "/tmp/b"))
        state.toggle(URL(fileURLWithPath: "/tmp/c"))
        #expect(state.expandedURLs.count == 3)
        state.collapseAll()
        #expect(state.expandedURLs.isEmpty)
    }

    // MARK: - Idempotency

    @Test func setExpandedTrueIsIdempotent() {
        let state = SidebarExpansionState()
        let url = URL(fileURLWithPath: "/tmp/folder")
        state.setExpanded(url, true)
        state.setExpanded(url, true)
        state.setExpanded(url, true)
        #expect(state.expandedURLs.count == 1)
    }

    // MARK: - prune(toMatch:)

    @Test func pruneRemovesURLsNotInTree() throws {
        let root = try makeTempTree(["alive", "alive/inner", "doomed"])
        defer { try? FileManager.default.removeItem(at: root) }

        let rootNode = FileNode(url: root)
        let state = SidebarExpansionState()
        let aliveURL = root.appendingPathComponent("alive")
        let innerURL = root.appendingPathComponent("alive/inner")
        let doomedURL = root.appendingPathComponent("doomed")
        let ghostURL = root.appendingPathComponent("never-existed")

        state.setExpanded(rootNode.url, true)
        state.setExpanded(aliveURL, true)
        state.setExpanded(innerURL, true)
        state.setExpanded(ghostURL, true)
        state.setExpanded(doomedURL, true)

        // Delete "doomed" then rebuild the tree to mimic refreshFileTree.
        try FileManager.default.removeItem(at: doomedURL)
        let refreshed = FileNode(url: root)
        state.prune(toMatch: [refreshed])

        #expect(state.isExpanded(rootNode.url))
        #expect(state.isExpanded(aliveURL))
        #expect(state.isExpanded(innerURL))
        #expect(!state.isExpanded(doomedURL))
        #expect(!state.isExpanded(ghostURL))
    }

    @Test func pruneEmptyTreeClearsState() {
        let state = SidebarExpansionState()
        state.setExpanded(URL(fileURLWithPath: "/tmp/x"), true)
        state.prune(toMatch: [])
        #expect(state.expandedURLs.isEmpty)
    }

    @Test func pruneKeepsDeepNestedFolders() throws {
        let root = try makeTempTree(["a/b/c/d/e"])
        defer { try? FileManager.default.removeItem(at: root) }

        let rootNode = FileNode(url: root)
        let state = SidebarExpansionState()
        let deep = root.appendingPathComponent("a/b/c/d/e")
        state.setExpanded(deep, true)
        state.prune(toMatch: [rootNode])
        #expect(state.isExpanded(deep))
    }

    // MARK: - Edge: massive number of folders

    @Test func canHoldThousandsOfExpandedFolders() {
        let state = SidebarExpansionState()
        for index in 0..<5000 {
            state.setExpanded(URL(fileURLWithPath: "/tmp/folder-\(index)"), true)
        }
        #expect(state.expandedURLs.count == 5000)
        state.collapseAll()
        #expect(state.expandedURLs.isEmpty)
    }
}
