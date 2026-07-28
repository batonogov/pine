//
//  CommandOverlayRouterTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Command overlay router")
@MainActor
struct CommandOverlayRouterTests {

    @Test("Presenting a new flow replaces the active flow")
    func replacementIsDeterministic() {
        let router = CommandOverlayRouter()

        router.present(.quickOpen)
        router.present(.commandPalette)

        #expect(router.activePresentation == .commandPalette)
        #expect(router.isPresented)
    }

    @Test("An obsolete flow cannot dismiss its replacement")
    func staleDismissIsIgnored() {
        let router = CommandOverlayRouter()
        router.present(.quickOpen)
        router.present(.symbolNavigator)

        router.dismiss(ifMatching: .quickOpen)

        #expect(router.activePresentation == .symbolNavigator)
        router.dismiss(ifMatching: .symbolNavigator)
        #expect(!router.isPresented)
    }

    @Test("Independent project routers do not dismiss each other")
    func routersAreIndependent() {
        let first = CommandOverlayRouter()
        let second = CommandOverlayRouter()
        first.present(.quickOpen)
        second.present(.goToLine)

        first.dismiss()

        #expect(!first.isPresented)
        #expect(second.activePresentation == .goToLine)
    }

    @Test("Replacement restores an arbitrary original AppKit responder")
    func replacementPreservesOriginalResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let original = CommandOverlayResponderView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 40)
        )
        let intermediate = CommandOverlayResponderView(
            frame: NSRect(x: 0, y: 50, width: 100, height: 40)
        )
        let contentView = try #require(window.contentView)
        contentView.addSubview(original)
        contentView.addSubview(intermediate)
        #expect(window.makeFirstResponder(original))

        let router = CommandOverlayRouter()
        router.present(.quickOpen, in: window)
        #expect(router.capturedResponder === original)

        #expect(window.makeFirstResponder(intermediate))
        router.present(.commandPalette, in: window)
        #expect(router.capturedResponder === original)

        router.dismiss()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))

        #expect(window.firstResponder === original)
        #expect(router.capturedResponder == nil)
    }

    @Test("Palette overlay command replaces the panel in the same session")
    func paletteOverlayCommandReplacesInPlace() {
        let router = CommandOverlayRouter()
        router.present(.commandPalette)

        CommandPaletteInvocationRouter.invoke(
            paletteItem(for: .quickOpen),
            projectManager: ProjectManager(),
            overlayRouter: router
        )

        #expect(router.activePresentation == .quickOpen)
    }

    @Test("Palette document command is targeted after dismissal")
    func paletteDocumentCommandDismissesThenDispatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-command-overlay-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectManager = ProjectManager()
        projectManager.workspace.loadDirectory(url: directory)
        let router = CommandOverlayRouter()
        router.present(.commandPalette)

        let center = NotificationCenter()
        let probe = CommandOverlayNotificationProbe()
        let projectIdentifier = ObjectIdentifier(projectManager)
        let token = center.addObserver(
            forName: .showProjectSearch,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(notification.object as AnyObject?)
        }
        defer { center.removeObserver(token) }

        CommandPaletteInvocationRouter.invoke(
            paletteItem(for: .findInProject),
            projectManager: projectManager,
            overlayRouter: router,
            notificationCenter: center
        )

        #expect(router.activePresentation == nil)
        #expect(probe.values.isEmpty)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let target = try #require(probe.values.first)
        #expect(target == projectIdentifier)
        #expect(probe.values.count == 1)
    }

    @Test("Command panel is key-capable and document scoped")
    func panelConfiguration() {
        let panel = CommandOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240)
        )
        defer { panel.close() }

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
    }

    @Test("A key command panel resolves to its document owner")
    func panelResolvesDocumentOwner() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let panel = CommandOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240)
        )
        defer {
            owner.removeChildWindow(panel)
            panel.close()
            owner.close()
        }
        owner.addChildWindow(panel, ordered: .above)

        #expect(
            CommandOverlayOwnerResolver.documentWindow(for: panel) === owner
        )
        #expect(
            CommandOverlayOwnerResolver.documentWindow(for: owner) === owner
        )
        #expect(
            CommandOverlayOwnerResolver.documentWindow(for: nil) == nil
        )
    }

    private func paletteItem(
        for command: UserCommand
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: .builtIn(command),
            title: command.localizedTitle,
            subtitle: command.category.localizedTitle,
            searchTerms: [],
            iconName: command.iconName,
            shortcut: CommandShortcutPresentation(
                chord: nil,
                state: .none
            ),
            isEnabled: true
        )
    }
}

@MainActor
private final class CommandOverlayResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

nonisolated private final class CommandOverlayNotificationProbe:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ObjectIdentifier?] = []

    var values: [ObjectIdentifier?] {
        lock.withLock { storage }
    }

    func record(_ value: AnyObject?) {
        lock.withLock {
            storage.append(value.map(ObjectIdentifier.init))
        }
    }
}
