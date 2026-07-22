//
//  TabTransferSafetyTests.swift
//  PineTests
//
//  Regression coverage for atomic editor-tab transfers between panes (#1169).
//

import Foundation
import Testing

@testable import Pine

@Suite("Editor tab transfer safety")
@MainActor
struct TabTransferSafetyTests {

    @discardableResult
    private func appendTab(
        to manager: TabManager,
        path: String,
        content: String = "",
        savedContent: String = "",
        isPinned: Bool = false
    ) -> EditorTab {
        var tab = EditorTab(
            url: URL(fileURLWithPath: path),
            content: content,
            savedContent: savedContent
        )
        tab.isPinned = isPinned
        manager.tabs.append(tab)
        manager.activeTabID = tab.id
        return tab
    }

    @Test("center transfer preserves identity, dirty state, recovery, and focus")
    func centerTransferPreservesIdentityDirtyRecoveryAndFocus() throws {
        let recoveryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-tab-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recoveryDirectory) }

        let recovery = RecoveryManager(recoveryDirectory: recoveryDirectory)
        let paneManager = PaneManager()
        paneManager.configureEditorTabManager = { $0.recoveryManager = recovery }

        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let moved = appendTab(
            to: source,
            path: "/tmp/dirty-transfer.swift",
            content: "let answer = 42",
            savedContent: "let answer = 0"
        )
        _ = appendTab(to: source, path: "/tmp/source-keeper.swift")
        source.activeTabID = moved.id
        recovery.snapshotDirtyTabs(source.tabs)
        #expect(recovery.pendingRecoveryEntries().contains { $0.0 == moved.id })

        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let didMove = paneManager.moveTabBetweenPanes(
            tabID: moved.id,
            tabURL: moved.url,
            from: sourceID,
            to: destinationID
        )

        #expect(didMove)
        let destination = try #require(paneManager.tabManager(for: destinationID))
        let transferred = try #require(destination.tabs.first)
        #expect(transferred.id == moved.id)
        #expect(transferred.content == moved.content)
        #expect(transferred.savedContent == moved.savedContent)
        #expect(transferred.isDirty)
        #expect(destination.activeTabID == moved.id)
        #expect(paneManager.activePaneID == destinationID)
        #expect(!source.tabs.contains { $0.id == moved.id })
        #expect(recovery.pendingRecoveryEntries().contains { $0.0 == moved.id })
    }

    @Test("pinned transfer joins destination pinned prefix")
    func pinnedTransferJoinsDestinationPinnedPrefix() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let moved = appendTab(to: source, path: "/tmp/moved-pinned.swift", isPinned: true)
        _ = appendTab(to: source, path: "/tmp/source-keeper.swift")

        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let destination = try #require(paneManager.tabManager(for: destinationID))
        let existingPinned = appendTab(
            to: destination,
            path: "/tmp/existing-pinned.swift",
            isPinned: true
        )
        let existingRegular = appendTab(to: destination, path: "/tmp/existing-regular.swift")

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: moved.id,
            tabURL: moved.url,
            from: sourceID,
            to: destinationID
        )

        #expect(didMove)
        #expect(destination.tabs.map(\.id) == [existingPinned.id, moved.id, existingRegular.id])
        #expect(destination.tabs.prefix(2).allSatisfy { $0.isPinned })
        #expect(!destination.tabs[2].isPinned)
        #expect(destination.activeTabID == moved.id)
    }

    @Test("tab ID wins when the source contains duplicate URLs")
    func tabIDDisambiguatesDuplicateURLs() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let duplicatePath = "/tmp/duplicate.swift"
        let first = appendTab(to: source, path: duplicatePath, content: "first")
        let second = appendTab(to: source, path: duplicatePath, content: "second")

        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let didMove = paneManager.moveTabBetweenPanes(
            tabID: second.id,
            tabURL: second.url,
            from: sourceID,
            to: destinationID
        )

        #expect(didMove)
        #expect(source.tabs.map(\.id) == [first.id])
        let destination = try #require(paneManager.tabManager(for: destinationID))
        #expect(destination.tabs.map(\.id) == [second.id])
        #expect(destination.tabs.first?.content == "second")
    }

    @Test("moving the sole tab prunes the source pane")
    func soleTabTransferPrunesSource() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let moved = appendTab(to: source, path: "/tmp/sole.swift")

        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let destination = try #require(paneManager.tabManager(for: destinationID))
        _ = appendTab(to: destination, path: "/tmp/destination-keeper.swift")

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: moved.id,
            tabURL: moved.url,
            from: sourceID,
            to: destinationID
        )

        #expect(didMove)
        #expect(paneManager.tabManager(for: sourceID) == nil)
        #expect(paneManager.root.leafCount == 1)
        #expect(paneManager.activePaneID == destinationID)
        #expect(destination.activeTabID == moved.id)
    }

    @Test("edge transfer prunes its empty source and activates the new pane")
    func edgeTransferPrunesSourceAndActivatesDestination() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let moved = appendTab(to: source, path: "/tmp/edge.swift")

        let targetID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let target = try #require(paneManager.tabManager(for: targetID))
        _ = appendTab(to: target, path: "/tmp/target.swift")

        let destinationID = try #require(paneManager.splitPane(
            targetID,
            axis: .vertical,
            tabID: moved.id,
            tabURL: moved.url,
            sourcePane: sourceID
        ))

        #expect(paneManager.tabManager(for: sourceID) == nil)
        #expect(paneManager.root.leafCount == 2)
        let destination = try #require(paneManager.tabManager(for: destinationID))
        #expect(destination.tabs.map(\.id) == [moved.id])
        #expect(destination.activeTabID == moved.id)
        #expect(paneManager.activePaneID == destinationID)
    }

    @Test("failed transfer leaves source, tree, and focus unchanged")
    func failedTransferIsAtomic() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let sourceTab = appendTab(to: source, path: "/tmp/source.swift")
        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        paneManager.activePaneID = sourceID

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: UUID(),
            from: sourceID,
            to: destinationID
        )

        #expect(!didMove)
        #expect(source.tabs.map(\.id) == [sourceTab.id])
        #expect(paneManager.tabManager(for: destinationID)?.tabs.isEmpty == true)
        #expect(paneManager.root.leafCount == 2)
        #expect(paneManager.activePaneID == sourceID)

        let leafCountBeforeFailedSplit = paneManager.root.leafCount
        let splitResult = paneManager.splitPane(
            destinationID,
            axis: .vertical,
            tabID: UUID(),
            sourcePane: sourceID
        )
        #expect(splitResult == nil)
        #expect(source.tabs.map(\.id) == [sourceTab.id])
        #expect(paneManager.root.leafCount == leafCountBeforeFailedSplit)
        #expect(paneManager.activePaneID == sourceID)
    }

    @Test("failed insertion can restore exact source order and selection")
    func extractionRollbackRestoresSourceExactly() throws {
        let manager = TabManager()
        let first = appendTab(to: manager, path: "/tmp/rollback-first.swift")
        let moved = appendTab(to: manager, path: "/tmp/rollback-moved.swift")
        let last = appendTab(to: manager, path: "/tmp/rollback-last.swift")
        manager.activeTabID = moved.id

        let extraction = try #require(manager.extractTab(id: moved.id))
        #expect(manager.tabs.map(\.id) == [first.id, last.id])
        #expect(manager.activeTabID == last.id)

        manager.restoreExtractedTab(extraction)

        #expect(manager.tabs.map(\.id) == [first.id, moved.id, last.id])
        #expect(manager.activeTabID == moved.id)
    }

    @Test("duplicate destination identity rejects transfer without extraction")
    func duplicateDestinationIdentityLeavesSourceUntouched() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let sourceTab = appendTab(to: source, path: "/tmp/duplicate-id.swift")
        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let destination = try #require(paneManager.tabManager(for: destinationID))
        var duplicateIdentity = sourceTab
        duplicateIdentity.url = URL(fileURLWithPath: "/tmp/other-url.swift")
        destination.tabs.append(duplicateIdentity)
        destination.activeTabID = sourceTab.id
        paneManager.activePaneID = sourceID

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: sourceTab.id,
            tabURL: sourceTab.url,
            from: sourceID,
            to: destinationID
        )

        #expect(!didMove)
        #expect(source.tabs.map(\.id) == [sourceTab.id])
        #expect(destination.tabs.map(\.id) == [sourceTab.id])
        #expect(paneManager.activePaneID == sourceID)
    }

    @Test("duplicate destination URL rejects transfer without extraction")
    func duplicateDestinationURLLeavesBothManagersUntouched() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let sourceTab = appendTab(to: source, path: "/tmp/same-file.swift", content: "source")
        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let destination = try #require(paneManager.tabManager(for: destinationID))
        let destinationTab = appendTab(
            to: destination,
            path: "/tmp/./same-file.swift",
            content: "destination"
        )
        paneManager.activePaneID = sourceID

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: sourceTab.id,
            tabURL: sourceTab.url,
            from: sourceID,
            to: destinationID
        )

        #expect(!didMove)
        #expect(source.tabs.map(\.id) == [sourceTab.id])
        #expect(source.tabs.first?.content == "source")
        #expect(destination.tabs.map(\.id) == [destinationTab.id])
        #expect(destination.tabs.first?.content == "destination")
        #expect(destination.activeTabID == destinationTab.id)
        #expect(paneManager.activePaneID == sourceID)
        #expect(paneManager.root.leafCount == 2)
    }

    @Test("stale tab identity never falls back to a matching URL")
    func staleTabIdentityDoesNotMoveAnotherTabByURL() throws {
        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let sourceTab = appendTab(to: source, path: "/tmp/stale-identity.swift")
        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        paneManager.activePaneID = sourceID

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: UUID(),
            tabURL: sourceTab.url,
            from: sourceID,
            to: destinationID
        )

        #expect(!didMove)
        #expect(source.tabs.map(\.id) == [sourceTab.id])
        #expect(paneManager.tabManager(for: destinationID)?.tabs.isEmpty == true)
        #expect(paneManager.activePaneID == sourceID)
        #expect(paneManager.root.leafCount == 2)
    }

    @Test("source and destination pending auto-saves both survive a transfer")
    func pendingAutoSavesSurviveTransferIntoNonemptyPane() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-transfer-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.swift")
        let destinationURL = directory.appendingPathComponent("destination.swift")
        try "source saved".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "destination saved".write(to: destinationURL, atomically: true, encoding: .utf8)

        let paneManager = PaneManager()
        let sourceID = paneManager.activePaneID
        let source = try #require(paneManager.tabManager(for: sourceID))
        let moved = appendTab(
            to: source,
            path: sourceURL.path,
            content: "source modified",
            savedContent: "source saved"
        )
        let sourceKeeper = appendTab(
            to: source,
            path: directory.appendingPathComponent("keeper.swift").path,
            content: "keeper",
            savedContent: "keeper"
        )
        let destinationID = try #require(paneManager.splitPane(sourceID, axis: .horizontal))
        let destination = try #require(paneManager.tabManager(for: destinationID))
        let destinationTab = appendTab(
            to: destination,
            path: destinationURL.path,
            content: "destination modified",
            savedContent: "destination saved"
        )
        let defaultsSuite = "TabTransferSafetyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        settings.formatOnSave = false
        destination.editorSettings = settings
        source.setAutoSaveDelay(0.1)
        destination.setAutoSaveDelay(0.1)
        defer {
            source.cancelAutoSave()
            destination.cancelAutoSave()
        }

        source.activeTabID = moved.id
        source.scheduleAutoSave()
        // The pending timer belongs to the moved tab even after selection
        // changes; dragging an inactive tab must transfer that timer too.
        source.activeTabID = sourceKeeper.id
        destination.scheduleAutoSave()
        #expect(source.hasScheduledAutoSave)
        #expect(destination.hasScheduledAutoSave(for: destinationTab.id))

        let didMove = paneManager.moveTabBetweenPanes(
            tabID: moved.id,
            tabURL: moved.url,
            from: sourceID,
            to: destinationID
        )

        #expect(didMove)
        #expect(!source.hasScheduledAutoSave)
        #expect(destination.hasScheduledAutoSave)
        #expect(destination.hasScheduledAutoSave(for: moved.id))
        #expect(destination.hasScheduledAutoSave(for: destinationTab.id))
        #expect(destination.activeTabID == moved.id)

        try await Task.sleep(for: .milliseconds(300))

        #expect(!destination.hasScheduledAutoSave)
        #expect(destination.tabs.first(where: { $0.id == moved.id })?.isDirty == false)
        #expect(destination.tabs.first(where: { $0.id == destinationTab.id })?.isDirty == false)
        #expect(try String(contentsOf: sourceURL, encoding: .utf8) == "source modified")
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "destination modified")
    }

    @Test("TabManager configurator covers existing, split, and restored managers")
    func tabManagerConfiguratorCoversEveryManager() throws {
        let paneManager = PaneManager()
        var configured: [ObjectIdentifier] = []
        paneManager.configureEditorTabManager = { configured.append(ObjectIdentifier($0)) }

        let initialID = paneManager.activePaneID
        let initialManager = try #require(paneManager.tabManager(for: initialID))
        #expect(configured == [ObjectIdentifier(initialManager)])

        let splitID = try #require(paneManager.splitPane(initialID, axis: .horizontal))
        let splitManager = try #require(paneManager.tabManager(for: splitID))
        #expect(configured.contains(ObjectIdentifier(splitManager)))

        let restoredA = PaneID()
        let restoredB = PaneID()
        let restoredRoot = PaneNode.split(
            .horizontal,
            first: .leaf(restoredA, .editor),
            second: .leaf(restoredB, .editor),
            ratio: 0.5
        )
        paneManager.restoreLayout(from: restoredRoot, activePaneUUID: restoredB.id)

        let restoredManagers = try [
            #require(paneManager.tabManager(for: restoredA)),
            #require(paneManager.tabManager(for: restoredB))
        ]
        for manager in restoredManagers {
            #expect(configured.contains(ObjectIdentifier(manager)))
        }
        #expect(paneManager.activePaneID == restoredB)
    }
}
