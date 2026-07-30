//
//  GlobalTabSwitcherOverlayHostedTests.swift
//  PineTests
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Global Tab Switcher Overlay Hosted Accessibility", .serialized)
@MainActor
struct GlobalTabSwitcherOverlayHostedTests {
    @MainActor
    private final class AnnouncementRecorder {
        var messages: [String] = []

        func record(_ message: String) {
            messages.append(message)
        }
    }

    @MainActor
    private final class ScrollRecorder {
        struct Request: Equatable {
            let identity: GlobalTabIdentity
            let animated: Bool
        }

        var requests: [Request] = []

        func record(_ identity: GlobalTabIdentity, animated: Bool) {
            requests.append(Request(
                identity: identity,
                animated: animated
            ))
        }
    }

    private struct Harness: View {
        let projectManager: ProjectManager
        let reduceMotion: Bool
        let announce: GlobalTabSwitcherAnnouncer
        let observeScroll: GlobalTabSwitcherScrollObserver

        var body: some View {
            GlobalTabSwitcherOverlay(
                announce: announce,
                observeScroll: observeScroll,
                reduceMotionOverride: reduceMotion
            )
                .environment(projectManager.paneManager)
                .environment(projectManager.workspace)
                .environment(\.locale, Locale(identifier: "en"))
        }
    }

    private struct Fixture {
        let projectManager: ProjectManager
    }

    private struct HostedOverlay {
        let view: NSHostingView<Harness>
        let window: NSWindow

        var fittingSize: NSSize {
            view.fittingSize
        }
    }

    @Test("Hosted overlay announces the initial and cycled selection")
    func announcesSelectionChanges() throws {
        let fixture = try makeFixture()
        let recorder = AnnouncementRecorder()
        let hosted = host(
            fixture: fixture,
            reduceMotion: false,
            recorder: recorder
        )
        defer { hosted.window.orderOut(nil) }

        let initialPresentation = fixture.projectManager.paneManager
            .globalTabSwitcherPresentation(projectRoot: nil)
        try #require(
            initialPresentation.entries.indices.contains(
                initialPresentation.selectedIndex
            )
        )
        let initialTitle = initialPresentation.entries[
            initialPresentation.selectedIndex
        ].title
        #expect(recorder.messages.last?.contains(initialTitle) == true)

        fixture.projectManager.paneManager
            .advanceGlobalTabSwitcher(offset: 1)
        drainMainRunLoop()

        let cycledPresentation = fixture.projectManager.paneManager
            .globalTabSwitcherPresentation(projectRoot: nil)
        try #require(
            cycledPresentation.entries.indices.contains(
                cycledPresentation.selectedIndex
            )
        )
        let cycledTitle = cycledPresentation.entries[
            cycledPresentation.selectedIndex
        ].title
        #expect(recorder.messages.last?.contains(cycledTitle) == true)
        #expect(recorder.messages.count >= 2)
        withExtendedLifetime(hosted) {}
    }

    @Test(
        "Hosted overlay renders with either motion preference",
        arguments: [false, true]
    )
    func rendersWithMotionPreference(_ reduceMotion: Bool) throws {
        let fixture = try makeFixture()
        let recorder = AnnouncementRecorder()
        let scrolls = ScrollRecorder()
        let hosted = host(
            fixture: fixture,
            reduceMotion: reduceMotion,
            recorder: recorder,
            scrollRecorder: scrolls
        )
        defer { hosted.window.orderOut(nil) }

        #expect(hosted.fittingSize.width > 0)
        #expect(hosted.fittingSize.height > 0)
        #expect(!recorder.messages.isEmpty)

        fixture.projectManager.paneManager
            .advanceGlobalTabSwitcher(offset: 1)
        drainMainRunLoop()
        #expect(recorder.messages.count >= 2)
        #expect(scrolls.requests.last?.animated == !reduceMotion)
        withExtendedLifetime(hosted) {}
    }

    @Test("Hosted overlay consumes modal and selected row semantics")
    func accessibilitySemantics() throws {
        let fixture = try makeFixture(
            names: ["main.swift", "main.swift", "README.md"]
        )
        let recorder = AnnouncementRecorder()
        let hosted = host(
            fixture: fixture,
            reduceMotion: true,
            recorder: recorder
        )
        defer { hosted.window.orderOut(nil) }
        let locale = Locale(identifier: "en")
        let presentation = fixture.projectManager.paneManager
            .globalTabSwitcherPresentation(
                projectRoot: nil,
                locale: locale
            )
        let semantics = GlobalTabSwitcherAccessibilitySemantics(
            entries: presentation.entries,
            selectedIndex: presentation.selectedIndex,
            locale: locale
        )

        #expect(hosted.fittingSize.width > 0)
        #expect(hosted.fittingSize.height > 0)
        #expect(
            semantics.overlayIdentifier
                == AccessibilityID.globalTabSwitcherOverlay
        )
        #expect(
            semantics.listIdentifier
                == AccessibilityID.globalTabSwitcherList
        )
        #expect(semantics.isModal)
        #expect(recorder.messages.last == semantics.announcement.message)

        try #require(
            presentation.entries.indices.contains(
                presentation.selectedIndex
            )
        )
        let selectedEntry = presentation.entries[
            presentation.selectedIndex
        ]
        #expect(semantics.announcement.selectedID == selectedEntry.id)
        #expect(
            semantics.announcement.message.contains(selectedEntry.title)
        )
        let expectedIdentifiers = Set(presentation.entries.map {
            AccessibilityID.globalTabSwitcherItem($0.id)
        })
        #expect(semantics.rows.count == presentation.entries.count)
        #expect(Set(semantics.rows.map(\.identifier)) == expectedIdentifiers)
        #expect(
            Set(semantics.rows.map(\.identifier)).count
                == semantics.rows.count
        )

        let selectedRows = semantics.rows.filter(\.isSelected)
        let selectedRow = try #require(selectedRows.first)
        #expect(selectedRows.count == 1)
        #expect(
            selectedRow.identifier
                == AccessibilityID.globalTabSwitcherItem(selectedEntry.id)
        )
        #expect(selectedRow.label.contains(selectedEntry.title))
        #expect(selectedRow.label.contains(selectedEntry.paneContext))
        #expect(
            selectedEntry.detail.map {
                selectedRow.label.contains($0)
            } ?? true
        )
    }

    @Test("Initial reverse selection is visible in the real scroll viewport")
    func initialReverseSelectionIsScrolledIntoView() throws {
        let fixture = try makeFixture(
            names: (0..<40).map { "file-\($0).swift" },
            initialOffset: -1
        )
        let presentation = fixture.projectManager.paneManager
            .globalTabSwitcherPresentation(projectRoot: nil)
        try #require(
            presentation.entries.indices.contains(
                presentation.selectedIndex
            )
        )
        let selected = presentation.entries[presentation.selectedIndex].id
        #expect(presentation.selectedIndex == presentation.entries.count - 1)

        let announcements = AnnouncementRecorder()
        let scrolls = ScrollRecorder()
        let hosted = host(
            fixture: fixture,
            reduceMotion: false,
            recorder: announcements,
            scrollRecorder: scrolls
        )
        defer { hosted.window.orderOut(nil) }

        #expect(scrolls.requests.contains(
            ScrollRecorder.Request(identity: selected, animated: false)
        ))
        let scrollView = try #require(
            firstDescendant(of: NSScrollView.self, in: hosted.view)
        )
        let documentView = try #require(scrollView.documentView)
        #expect(
            documentView.bounds.height
                > scrollView.contentView.bounds.height
        )
        #expect(abs(scrollView.contentView.bounds.minY) > 1)
        withExtendedLifetime(hosted) {}
    }

    @Test("Replacing a selected identity re-announces equal spoken text")
    func staleReplacementWithSameTextIsAnnounced() throws {
        let fixture = try makeFixture(
            names: ["main.swift", "main.swift", "main.swift"],
            initialOffset: 1
        )
        let paneManager = fixture.projectManager.paneManager
        let paneID = paneManager.activePaneID
        let tabManager = try #require(paneManager.tabManager(for: paneID))
        let duplicateURL = URL(
            fileURLWithPath: "/tmp/shared/main.swift"
        )
        for index in tabManager.tabs.indices {
            tabManager.tabs[index].url = duplicateURL
        }
        let announcements = AnnouncementRecorder()
        let hosted = host(
            fixture: fixture,
            reduceMotion: true,
            recorder: announcements
        )
        defer { hosted.window.orderOut(nil) }
        let oldPresentation = paneManager.globalTabSwitcherPresentation(
            projectRoot: nil
        )
        try #require(
            oldPresentation.entries.indices.contains(
                oldPresentation.selectedIndex
            )
        )
        let oldIdentity = oldPresentation.entries[
            oldPresentation.selectedIndex
        ].id
        let oldMessage = try #require(announcements.messages.last)
        let oldCount = announcements.messages.count

        paneManager.cancelGlobalTabSwitcher()
        tabManager.closeTab(id: oldIdentity.tabID)
        let replacement = EditorTab(
            url: duplicateURL,
            content: "",
            savedContent: ""
        )
        tabManager.tabs.append(replacement)
        paneManager.selectEditorTab(replacement.id, in: paneID)
        #expect(paneManager.beginGlobalTabSwitcherSession(initialOffset: 1))

        let newPresentation = paneManager.globalTabSwitcherPresentation(
            projectRoot: nil
        )
        try #require(
            newPresentation.entries.indices.contains(
                newPresentation.selectedIndex
            )
        )
        let newIdentity = newPresentation.entries[
            newPresentation.selectedIndex
        ].id
        #expect(newIdentity != oldIdentity)

        drainMainRunLoop()
        #expect(announcements.messages.count > oldCount)
        #expect(announcements.messages.last == oldMessage)
        withExtendedLifetime(hosted) {}
    }

    private func makeFixture(
        names: [String] = ["main.swift", "main.swift", "README.md"],
        initialOffset: Int = 1
    ) throws -> Fixture {
        let projectManager = ProjectManager()
        let paneManager = projectManager.paneManager
        let paneID = paneManager.activePaneID
        let tabManager = try #require(paneManager.tabManager(for: paneID))

        for name in names {
            let tab = EditorTab(
                url: URL(fileURLWithPath: "/tmp/\(UUID())/\(name)"),
                content: "",
                savedContent: ""
            )
            tabManager.tabs.append(tab)
            paneManager.selectEditorTab(tab.id, in: paneID)
        }

        #expect(
            paneManager.beginGlobalTabSwitcherSession(
                initialOffset: initialOffset
            )
        )
        return Fixture(projectManager: projectManager)
    }

    private func host(
        fixture: Fixture,
        reduceMotion: Bool,
        recorder: AnnouncementRecorder,
        scrollRecorder: ScrollRecorder? = nil
    ) -> HostedOverlay {
        let hosted = NSHostingView(rootView: Harness(
            projectManager: fixture.projectManager,
            reduceMotion: reduceMotion,
            announce: { message in recorder.record(message) },
            observeScroll: { identity, animated in
                scrollRecorder?.record(identity, animated: animated)
            }
        ))
        hosted.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        let window = NSWindow(
            contentRect: hosted.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosted
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        // Give SwiftUI a normal key-window lifecycle. Serializing this suite
        // keeps that process-global window state deterministic.
        window.makeKeyAndOrderFront(nil)
        hosted.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        hosted.layoutSubtreeIfNeeded()
        return HostedOverlay(view: hosted, window: window)
    }

    private func firstDescendant<ViewType: NSView>(
        of type: ViewType.Type,
        in root: NSView
    ) -> ViewType? {
        if let match = root as? ViewType {
            return match
        }
        for subview in root.subviews {
            if let match = firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    }
}
