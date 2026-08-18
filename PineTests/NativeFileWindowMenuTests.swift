//
//  NativeFileWindowMenuTests.swift
//  PineTests
//
//  Regression coverage for issue #1275.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Native File and Window menu semantics", .serialized)
@MainActor
struct NativeFileWindowMenuTests {
    @Test("Native notification mutations defer to the next main runloop")
    func nativeCommandDeliveryIsDeferred() async {
        var deliveryCount = 0

        NativeCommandDelivery.deferToNextMainRunLoop {
            deliveryCount += 1
        }

        #expect(deliveryCount == 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        #expect(deliveryCount == 1)
    }

    @Test("Untitled buffers are editable without a fabricated file path")
    func untitledBufferBackingAndNames() throws {
        let projectManager = ProjectManager()

        let firstID = try #require(
            projectManager.createUntitledFile()
        )
        let first = try #require(
            projectManager.activeTabManager.tabs.first(where: {
                $0.id == firstID
            })
        )
        #expect(first.fileURL == nil)
        #expect(first.url.scheme == "pine-untitled")
        #expect(first.fileName == Strings.recoveryUntitled)

        projectManager.activeTabManager.updateContent("draft")
        #expect(projectManager.activeTabManager.activeTab?.isDirty == true)

        let secondID = try #require(
            projectManager.createUntitledFile()
        )
        let second = try #require(
            projectManager.activeTabManager.tabs.first(where: {
                $0.id == secondID
            })
        )
        #expect(second.fileName == "\(Strings.recoveryUntitled) 2")
    }

    @Test("New File retains its captured editor pane across focus drift")
    func newFileTargetsCapturedPane() throws {
        let projectManager = ProjectManager()
        let firstPaneID = projectManager.paneManager.activePaneID
        let firstTabManager = try #require(
            projectManager.paneManager.tabManager(for: firstPaneID)
        )
        let secondPaneID = try #require(
            projectManager.paneManager.splitPane(
                firstPaneID,
                axis: .horizontal
            )
        )
        let secondTabManager = try #require(
            projectManager.paneManager.tabManager(for: secondPaneID)
        )
        #expect(projectManager.paneManager.activePaneID == secondPaneID)

        let createdID = try #require(
            projectManager.createUntitledFile(in: firstPaneID)
        )

        #expect(
            firstTabManager.tabs.contains(where: {
                $0.id == createdID
            })
        )
        #expect(
            !secondTabManager.tabs.contains(where: {
                $0.id == createdID
            })
        )
        #expect(projectManager.paneManager.activePaneID == firstPaneID)
    }

    @Test("Saving an untitled tab preserves the exact tab across focus drift")
    func untitledSaveTargetsCapturedIdentity() async throws {
        let projectManager = ProjectManager()
        let firstID = try #require(projectManager.createUntitledFile())
        let tabManager = projectManager.activeTabManager
        tabManager.updateContent("first draft\n")
        let secondID = try #require(projectManager.createUntitledFile())
        tabManager.updateContent("second draft\n")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-untitled-save-\(UUID().uuidString).txt"
            )
        defer { try? FileManager.default.removeItem(at: destination) }

        projectManager.saveDestinationChooser = { tab, _, _ in
            #expect(tab.id == firstID)
            tabManager.activeTabID = secondID
            return destination
        }

        #expect(await projectManager.saveTab(
            tabID: firstID,
            in: tabManager,
            forceSaveAs: false,
            context: .unscoped
        ))

        let first = try #require(
            tabManager.tabs.first(where: { $0.id == firstID })
        )
        let second = try #require(
            tabManager.tabs.first(where: { $0.id == secondID })
        )
        #expect(first.fileURL == destination)
        #expect(!first.isDirty)
        #expect(second.fileURL == nil)
        #expect(second.isDirty)
        #expect(tabManager.activeTabID == secondID)
        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == first.savedContent
        )
    }

    @Test("Dirty untitled close fails closed when Save is cancelled")
    func dirtyUntitledCloseRequiresDestination() async throws {
        let projectManager = ProjectManager()
        let tabID = try #require(projectManager.createUntitledFile())
        let tabManager = projectManager.activeTabManager
        tabManager.updateContent("unsaved")
        let captured = try #require(tabManager.activeTab)
        var chooserCalls = 0
        projectManager.saveDestinationChooser = { tab, _, _ in
            chooserCalls += 1
            #expect(tab.id == tabID)
            return nil
        }

        let closed = await TabCloseHelper.closeTab(
            captured,
            in: tabManager,
            gitProvider: projectManager.workspace.gitProvider,
            context: .unscoped,
            presentAlert: { .alertFirstButtonReturn },
            saveTab: { index in
                guard tabManager.tabs.indices.contains(index) else {
                    return false
                }
                return await projectManager.saveTab(
                    tabID: tabManager.tabs[index].id,
                    in: tabManager,
                    forceSaveAs: false,
                    context: .unscoped
                )
            }
        )

        #expect(!closed)
        #expect(chooserCalls == 1)
        #expect(tabManager.tabs.map(\.id) == [tabID])
        #expect(tabManager.activeTab?.isDirty == true)
        #expect(tabManager.activeTab?.fileURL == nil)
    }

    @Test("Native enablement follows the focused pane and pinned state")
    func focusedPaneEnablementAndPinnedClose() throws {
        let root = try makeTemporaryDirectory(
            prefix: "pine-native-state-root"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let projectManager = ProjectManager()
        projectManager.workspace.loadDirectory(url: root)
        let tabID = try #require(projectManager.createUntitledFile())
        let tabManager = projectManager.activeTabManager

        var state = NativeMenuCommandState(
            projectManager: projectManager
        )
        #expect(state.activeEditorTabID == tabID)
        #expect(state.canSave)
        #expect(state.canSaveAs)
        #expect(!state.canDuplicate)
        #expect(state.canCloseTab)

        tabManager.togglePin(id: tabID)
        state = NativeMenuCommandState(projectManager: projectManager)
        #expect(!state.canCloseTab)
        #expect(tabManager.closeTab(id: tabID) == .pinned)
        #expect(tabManager.tabs.contains(where: { $0.id == tabID }))

        let editorPaneID = projectManager.paneManager.activePaneID
        let terminalPaneID = try #require(
            projectManager.paneManager.createTerminalPane(
                relativeTo: editorPaneID,
                axis: .vertical,
                workingDirectory: nil
            )
        )
        let terminalTabID = try #require(
            projectManager.paneManager
                .terminalState(for: terminalPaneID)?
                .activeTerminalID
        )

        state = NativeMenuCommandState(projectManager: projectManager)
        #expect(state.activeEditorTabID == nil)
        #expect(!state.canSave)
        #expect(!state.canSaveAs)
        #expect(state.canCloseTab)
        #expect(
            state.closeTarget == .terminal(
                paneID: terminalPaneID,
                tabID: terminalTabID
            )
        )
    }

    @Test("Native window commands fail closed without a project root")
    func rootlessProjectHasNoNativeWindowDestination() throws {
        let projectManager = ProjectManager()
        _ = try #require(projectManager.createUntitledFile())

        let state = NativeMenuCommandState(
            projectManager: projectManager
        )
        #expect(!state.canCloseTab)
        #expect(!state.canCloseWindow)
        #expect(
            !UserCommandInvocationRouter.context(
                for: projectManager
            ).satisfies(.project)
        )
    }

    @Test("Save All preflights every pane before writing any file")
    func saveAllRejectsTruncatedPaneWithoutPartialWrite() async throws {
        let root = try makeTemporaryDirectory(
            prefix: "pine-save-all-preflight"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstFile = root.appendingPathComponent("first.txt")
        let secondFile = root.appendingPathComponent("second.txt")
        try "first original\n".write(
            to: firstFile,
            atomically: true,
            encoding: .utf8
        )
        try "second original\n".write(
            to: secondFile,
            atomically: true,
            encoding: .utf8
        )

        let projectManager = ProjectManager()
        projectManager.workspace.loadDirectory(url: root)
        let firstPaneID = projectManager.paneManager.activePaneID
        let firstTabManager = try #require(
            projectManager.paneManager.tabManager(for: firstPaneID)
        )
        #expect(firstTabManager.openTab(url: firstFile) != .cancelled)
        firstTabManager.updateContent("first changed\n")

        let secondPaneID = try #require(
            projectManager.paneManager.splitPane(
                firstPaneID,
                axis: .horizontal
            )
        )
        let secondTabManager = try #require(
            projectManager.paneManager.tabManager(for: secondPaneID)
        )
        #expect(secondTabManager.openTab(url: secondFile) != .cancelled)
        secondTabManager.updateContent("second changed\n")
        let secondIndex = try #require(
            secondTabManager.tabs.firstIndex(where: {
                $0.fileURL == secondFile
            })
        )
        secondTabManager.tabs[secondIndex].isTruncated = true

        let state = NativeMenuCommandState(
            projectManager: projectManager
        )
        #expect(!state.canSaveAll)
        let didSave = await projectManager.saveAllPaneTabs(
            context: .unscoped
        )
        #expect(!didSave)
        #expect(!projectManager.saveAllPaneTabs())
        #expect(
            try String(contentsOf: firstFile, encoding: .utf8)
                == "first original\n"
        )
        #expect(
            try String(contentsOf: secondFile, encoding: .utf8)
                == "second original\n"
        )
        #expect(firstTabManager.activeTab?.isDirty == true)
        #expect(secondTabManager.activeTab?.isDirty == true)
    }

    @Test("Save All cancellation preflights every untitled destination")
    func saveAllUntitledCancellationDoesNotPartiallyWrite() async throws {
        let projectManager = ProjectManager()
        let firstID = try #require(
            projectManager.createUntitledFile()
        )
        let tabManager = projectManager.activeTabManager
        tabManager.updateContent("first draft\n")
        let secondID = try #require(
            projectManager.createUntitledFile()
        )
        tabManager.updateContent("second draft\n")

        let firstDestination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-save-all-first-\(UUID().uuidString).txt"
            )
        defer {
            try? FileManager.default.removeItem(at: firstDestination)
        }
        var chooserTabIDs: [UUID] = []
        projectManager.saveDestinationChooser = { tab, _, _ in
            chooserTabIDs.append(tab.id)
            return tab.id == firstID ? firstDestination : nil
        }

        #expect(
            !(await projectManager.saveAllPaneTabs(
                context: .unscoped
            ))
        )
        #expect(chooserTabIDs == [firstID, secondID])
        #expect(
            !FileManager.default.fileExists(
                atPath: firstDestination.path
            )
        )
        let first = try #require(
            tabManager.tabs.first(where: { $0.id == firstID })
        )
        let second = try #require(
            tabManager.tabs.first(where: { $0.id == secondID })
        )
        #expect(first.fileURL == nil)
        #expect(first.isDirty)
        #expect(second.fileURL == nil)
        #expect(second.isDirty)
    }

    @Test("Save All rejects an untitled destination already open in a tab")
    func saveAllRejectsOpenFileDestinationCollision() async throws {
        let root = try makeTemporaryDirectory(
            prefix: "pine-save-all-destination-collision"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let existingFile = root.appendingPathComponent("existing.txt")
        try "disk original\n".write(
            to: existingFile,
            atomically: true,
            encoding: .utf8
        )

        let projectManager = ProjectManager()
        projectManager.workspace.loadDirectory(url: root)
        let tabManager = projectManager.activeTabManager
        #expect(tabManager.openTab(url: existingFile) != .cancelled)
        tabManager.updateContent("file-backed draft\n")

        let untitledID = try #require(
            projectManager.createUntitledFile()
        )
        tabManager.updateContent("untitled draft\n")
        projectManager.saveDestinationChooser = { _, _, _ in
            existingFile
        }

        #expect(
            !(await projectManager.saveAllPaneTabs(
                context: .unscoped
            ))
        )
        #expect(
            try String(contentsOf: existingFile, encoding: .utf8)
                == "disk original\n"
        )
        let fileBacked = try #require(
            tabManager.tabs.first(where: {
                $0.fileURL == existingFile
            })
        )
        let untitled = try #require(
            tabManager.tabs.first(where: {
                $0.id == untitledID
            })
        )
        #expect(fileBacked.isDirty)
        #expect(fileBacked.content == "file-backed draft\n")
        #expect(untitled.fileURL == nil)
        #expect(untitled.isDirty)
        #expect(untitled.content == "untitled draft\n")
    }

    @Test("Targeted native commands do not drift to another key project")
    func multiWindowRoutingUsesProjectIdentity() throws {
        let first = ProjectManager()
        let second = ProjectManager()
        let candidates = [
            NativeCommandRoutingCandidate(
                projectManager: first,
                isKeyWindow: false
            ),
            NativeCommandRoutingCandidate(
                projectManager: second,
                isKeyWindow: true
            ),
        ]

        #expect(
            NativeCommandRouting.destinationIndex(
                requestedProject: first,
                candidates: candidates
            ) == 0
        )
        #expect(
            NativeCommandRouting.destinationIndex(
                requestedProject: nil,
                candidates: candidates
            ) == 1
        )
        #expect(
            NativeCommandRouting.destinationIndex(
                requestedProject: ProjectManager(),
                candidates: candidates
            ) == nil
        )

        let staleAndLive = [
            NativeCommandRoutingCandidate(
                projectManager: first,
                isKeyWindow: true,
                isEligibleWindow: false
            ),
            NativeCommandRoutingCandidate(
                projectManager: second,
                isKeyWindow: true
            ),
        ]
        #expect(
            NativeCommandRouting.destinationIndex(
                requestedProject: first,
                candidates: staleAndLive
            ) == nil
        )
        #expect(
            NativeCommandRouting.destinationIndex(
                requestedProject: nil,
                candidates: staleAndLive
            ) == 1
        )

        let staleThenReopened = [
            NativeCommandRoutingCandidate(
                projectManager: first,
                isKeyWindow: true,
                isEligibleWindow: false
            ),
            NativeCommandRoutingCandidate(
                projectManager: first,
                isKeyWindow: false
            ),
        ]
        #expect(
            NativeCommandRouting.destinationIndex(
                requestedProject: first,
                candidates: staleThenReopened
            ) == 1
        )
    }

    @Test("Open File retains the initiating project and pane across focus drift")
    func openFileUsesProjectScopedChooser() async throws {
        let root = try makeTemporaryDirectory(prefix: "pine-open-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.swift")
        try "let selected = true\n".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let defaults = makeIsolatedDefaults()
        let projectManager = ProjectManager(
            lspSettings: LSPSettings(defaults: defaults)
        )
        projectManager.workspace.loadDirectory(url: root)
        let firstTabID = try #require(
            projectManager.createUntitledFile()
        )
        let firstPaneID = projectManager.paneManager.activePaneID
        let firstTabManager = try #require(
            projectManager.paneManager.tabManager(for: firstPaneID)
        )
        let secondPaneID = try #require(
            projectManager.paneManager.splitPane(
                firstPaneID,
                axis: .horizontal
            )
        )
        let secondTabID = try #require(
            projectManager.createUntitledFile()
        )
        let secondTabManager = try #require(
            projectManager.paneManager.tabManager(for: secondPaneID)
        )
        #expect(
            projectManager.paneManager.selectEditorTab(
                firstTabID,
                in: firstPaneID
            )
        )
        var chooserRoot: URL?
        projectManager.openFileChooser = { rootURL, _ in
            chooserRoot = rootURL
            #expect(
                projectManager.paneManager.selectEditorTab(
                    secondTabID,
                    in: secondPaneID
                )
            )
            return file
        }

        projectManager.openFileFromMenu()
        for _ in 0..<20
        where !firstTabManager.tabs.contains(where: {
            $0.fileURL == file
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(chooserRoot == root)
        #expect(firstTabManager.tabs.contains(where: { $0.fileURL == file }))
        #expect(!secondTabManager.tabs.contains(where: { $0.fileURL == file }))
        #expect(projectManager.paneManager.activePaneID == firstPaneID)
    }

    @Test("Effective shortcuts replace and shadow built-in menu equivalents")
    func effectiveShortcutProjection() async throws {
        let directory = try makeTemporaryDirectory(
            prefix: "pine-native-shortcuts"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let keybindingsFile = directory.appendingPathComponent(
            "keybindings.json"
        )

        let registry = UserKeybindingRegistry()
        let commandK = try #require(
            UserKeybindingRegistry.parse("cmd+k")
        )
        try Data(
            #"[{"command": "closeTab", "key": "cmd+k"}]"#.utf8
        ).write(to: keybindingsFile)
        #expect(
            (await registry.load(from: keybindingsFile)).outcome
                == .loaded
        )
        #expect(registry.effectiveChord(for: .closeTab) == commandK)

        let shadowingRegistry = UserKeybindingRegistry()
        try Data(
            #"[{"command": "toggleComment", "key": "cmd+p"}]"#.utf8
        ).write(to: keybindingsFile)
        #expect(
            (await shadowingRegistry.load(from: keybindingsFile)).outcome
                == .loaded
        )
        #expect(
            shadowingRegistry.effectiveChord(for: .quickOpen) == nil
        )
        #expect(
            shadowingRegistry.effectiveChord(for: .closeTab)
                == UserKeybindingRegistry.parse("cmd+w")
        )
    }

    @Test("Recent projects canonicalize, prune, reorder, and clear")
    func sharedRecentProjectRegistry() throws {
        let first = try makeTemporaryDirectory(prefix: "pine-recent-a")
        let second = try makeTemporaryDirectory(prefix: "pine-recent-b")
        let symlink = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-recent-link-\(UUID().uuidString)"
            )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: first
        )
        defer {
            try? FileManager.default.removeItem(at: symlink)
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let defaults = makeIsolatedDefaults()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-recent-missing-\(UUID().uuidString)"
            )
        defaults.set(
            [
                symlink.path,
                first.path,
                missing.path,
                second.path,
            ],
            forKey: "recentProjectPaths"
        )
        let registry = ProjectRegistry(
            lspSettings: LSPSettings(defaults: defaults),
            defaults: defaults,
            clearRecentProjects: false
        )

        let canonicalFirst = first.standardizedFileURL
            .resolvingSymlinksInPath()
        let canonicalSecond = second.standardizedFileURL
            .resolvingSymlinksInPath()
        #expect(
            registry.recentProjects
                == [canonicalFirst, canonicalSecond]
        )
        #expect(
            defaults.stringArray(forKey: "recentProjectPaths")
                == [canonicalFirst.path, canonicalSecond.path]
        )

        _ = registry.projectManager(for: second)
        #expect(registry.recentProjects.first == canonicalSecond)
        _ = registry.projectManager(for: first)
        #expect(registry.recentProjects.first == canonicalFirst)

        registry.clearRecentProjects()
        #expect(registry.recentProjects.isEmpty)
        #expect(
            defaults.stringArray(forKey: "recentProjectPaths")?.isEmpty
                == true
        )
    }

    @Test("Open Recent uses the Welcome fallback without a SwiftUI bridge")
    func openRecentUsesWelcomeFallback() async throws {
        let directory = try makeTemporaryDirectory(
            prefix: "pine-recent-fallback"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = AppDelegate()
        delegate.registry = ProjectRegistry()
        delegate.openProjectWindow = nil
        var openedURL: URL?

        let didOpen = await delegate.openRecentProject(
            directory,
            fallbackOpenProjectWindow: { openedURL = $0 }
        )

        let canonical = delegate.registry.canonicalProjectURL(directory)
        #expect(didOpen)
        #expect(openedURL == canonical)
        #expect(delegate.registry.openProjects[canonical] != nil)
    }

    @Test("Open Recent raises the scene that already owns the project")
    func openRecentRaisesOwningScene() async throws {
        let root = try makeTemporaryDirectory(
            prefix: "pine-recent-owning-scene"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First", isDirectory: true)
        let second = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        let defaults = makeIsolatedDefaults()
        let registry = ProjectRegistry(
            lspSettings: LSPSettings(defaults: defaults),
            defaults: defaults,
            clearRecentProjects: false
        )
        _ = try #require(registry.projectManager(for: first))
        let session = ProjectWindowSession(
            initialProjectURL: first,
            defaults: defaults
        )
        await session.openProject(second, registry: registry)
        session.windowDidClose(registry: registry)
        registry.closeProjectWindow(second)
        registry.registerWindowSession(session)
        let delegate = AppDelegate()
        delegate.registry = registry
        delegate.openProjectWindow = nil
        var openedURL: URL?

        let didOpen = await delegate.openRecentProject(
            second,
            fallbackOpenProjectWindow: { openedURL = $0 }
        )

        #expect(didOpen)
        #expect(openedURL == session.sceneProjectURL)
        #expect(
            session.activeProjectURL
                == registry.canonicalProjectURL(second)
        )
    }

    @Test("Deferred Open Recent retains the Welcome fallback")
    func deferredOpenRecentUsesWelcomeFallback() async throws {
        let directory = try makeTemporaryDirectory(
            prefix: "pine-recent-deferred-fallback"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let delegate = AppDelegate()
        delegate.registry = ProjectRegistry()
        delegate.openProjectWindow = nil
        var openedURL: URL?

        delegate.requestOpenRecentProject(
            directory,
            fallbackOpenProjectWindow: { openedURL = $0 }
        )
        #expect(openedURL == nil)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        for _ in 0..<200 where openedURL == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }

        let canonical = delegate.registry.canonicalProjectURL(directory)
        #expect(openedURL == canonical)
        #expect(delegate.registry.openProjects[canonical] != nil)
    }

    @Test("Recent project titles disambiguate equal names and history caps at ten")
    func recentProjectTitlesAndLimit() throws {
        let firstParent = try makeTemporaryDirectory(
            prefix: "pine-recent-parent-a"
        )
        let secondParent = try makeTemporaryDirectory(
            prefix: "pine-recent-parent-b"
        )
        defer {
            try? FileManager.default.removeItem(at: firstParent)
            try? FileManager.default.removeItem(at: secondParent)
        }
        let firstProject = firstParent.appendingPathComponent(
            "Shared",
            isDirectory: true
        )
        let secondProject = secondParent.appendingPathComponent(
            "Shared",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstProject,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: secondProject,
            withIntermediateDirectories: false
        )
        let firstTitle = ProjectRegistry.recentProjectDisplayTitle(
            for: firstProject
        )
        let secondTitle = ProjectRegistry.recentProjectDisplayTitle(
            for: secondProject
        )
        #expect(firstTitle != secondTitle)
        #expect(firstTitle.hasPrefix("Shared — "))
        #expect(secondTitle.hasPrefix("Shared — "))

        let historyRoot = try makeTemporaryDirectory(
            prefix: "pine-recent-limit"
        )
        defer { try? FileManager.default.removeItem(at: historyRoot) }
        var projectURLs: [URL] = []
        for index in 0..<12 {
            let url = historyRoot.appendingPathComponent(
                "Project-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false
            )
            projectURLs.append(url)
        }
        let defaults = makeIsolatedDefaults()
        defaults.set(
            projectURLs.map(\.path),
            forKey: "recentProjectPaths"
        )
        let registry = ProjectRegistry(
            lspSettings: LSPSettings(defaults: defaults),
            defaults: defaults,
            clearRecentProjects: false
        )
        #expect(registry.recentProjects.count == 10)
        #expect(
            registry.recentProjects
                == projectURLs.prefix(10).map {
                    $0.standardizedFileURL.resolvingSymlinksInPath()
                }
        )
        #expect(
            defaults.stringArray(forKey: "recentProjectPaths")?.count
                == 10
        )
    }

    @Test("Native File and Window strings cover every supported locale")
    func nativeMenuLocalizationsAreComplete() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Pine/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        let strings = try #require(
            root["strings"] as? [String: Any]
        )
        let expectedLocales: Set<String> = [
            "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru",
            "zh-Hans",
        ]
        let keys = [
            "menu.newFile",
            "menu.open",
            "menu.openRecent",
            "menu.clearMenu",
            "menu.closeTab",
            "menu.closeWindow",
            "openFilePanel.message",
            "openFilePanel.prompt",
        ]

        for key in keys {
            let entry = try #require(
                strings[key] as? [String: Any]
            )
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == expectedLocales)
            for locale in expectedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty)
            }
        }
    }

    @Test("Untitled crash recovery retains name and unsaved content")
    func untitledRecoveryRoundTrip() async throws {
        let directory = try makeTemporaryDirectory(
            prefix: "pine-untitled-recovery"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = RecoveryManager(recoveryDirectory: directory)
        let source = EditorTab(
            untitledName: "Scratch",
            content: "unsaved draft",
            savedContent: ""
        )
        recovery.snapshotDirtyTabs([source])
        let pending = recovery.pendingRecoveryEntries()
        #expect(pending.count == 1)
        #expect(pending.first?.1.originalPath.isEmpty == true)
        #expect(pending.first?.1.untitledName == "Scratch")

        let tabManager = TabManager()
        let retained = await recovery.restorePendingEntries(
            pending,
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.isEmpty)
        #expect(tabManager.tabs.count == 1)
        #expect(tabManager.activeTab?.fileURL == nil)
        #expect(tabManager.activeTab?.fileName == "Scratch")
        #expect(tabManager.activeTab?.content == "unsaved draft")
        #expect(tabManager.activeTab?.isDirty == true)
        let migrated = recovery.pendingRecoveryEntries()
        #expect(migrated.count == 1)
        #expect(migrated.first?.0 == tabManager.activeTabID)
        #expect(migrated.first?.1.untitledName == "Scratch")
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "NativeFileWindowMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)
            ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
