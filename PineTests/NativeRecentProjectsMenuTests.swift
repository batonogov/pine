//
//  NativeRecentProjectsMenuTests.swift
//  PineTests
//

import AppKit
import Testing

@testable import Pine

@MainActor
private final class NativeRecentProjectsMenuTarget: NSObject {
    @objc func openProject(_: NSMenuItem) {}
    @objc func clearProjects(_: NSMenuItem) {}
}

@Suite("Native recent projects menu")
@MainActor
struct NativeRecentProjectsMenuTests {
    private func makeMenu() -> (main: NSMenu, openRecent: NSMenuItem) {
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(
            title: "File",
            action: nil,
            keyEquivalent: ""
        )
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let openRecent = NSMenuItem(
            title: String(localized: "menu.openRecent"),
            action: nil,
            keyEquivalent: ""
        )
        openRecent.submenu = NSMenu()
        fileMenu.addItem(openRecent)
        return (mainMenu, openRecent)
    }

    @Test("Builds localized recent entries and actions")
    func buildsRecentEntries() throws {
        let (mainMenu, openRecent) = makeMenu()
        let target = NativeRecentProjectsMenuTarget()
        let projects = [
            URL(fileURLWithPath: "/tmp/First Project"),
            URL(fileURLWithPath: "/tmp/Second Project"),
        ]

        #expect(NativeRecentProjectsMenu.synchronize(
            mainMenu: mainMenu,
            projects: projects,
            target: target,
            openAction:
                #selector(NativeRecentProjectsMenuTarget.openProject(_:)),
            clearAction:
                #selector(NativeRecentProjectsMenuTarget.clearProjects(_:))
        ))

        #expect(openRecent.isEnabled)
        let submenu = try #require(openRecent.submenu)
        #expect(submenu.items.count == 4)
        for (index, project) in projects.enumerated() {
            let item = submenu.items[index]
            #expect(
                item.title
                    == ProjectRegistry.recentProjectDisplayTitle(
                        for: project
                    )
            )
            #expect(item.representedObject as? URL == project)
            #expect(
                item.action
                    == #selector(
                        NativeRecentProjectsMenuTarget.openProject(_:)
                    )
            )
        }
        #expect(submenu.items[2].isSeparatorItem)
        #expect(
            submenu.items[3].title
                == String(localized: "menu.clearMenu")
        )
        #expect(submenu.items[3].isEnabled)
        #expect(
            submenu.items[3].action
                == #selector(
                    NativeRecentProjectsMenuTarget.clearProjects(_:)
                )
        )
    }

    @Test("Empty registry disables Open Recent and Clear Menu")
    func disablesEmptyMenu() throws {
        let (mainMenu, openRecent) = makeMenu()
        let target = NativeRecentProjectsMenuTarget()

        #expect(NativeRecentProjectsMenu.synchronize(
            mainMenu: mainMenu,
            projects: [],
            target: target,
            openAction:
                #selector(NativeRecentProjectsMenuTarget.openProject(_:)),
            clearAction:
                #selector(NativeRecentProjectsMenuTarget.clearProjects(_:))
        ))

        #expect(!openRecent.isEnabled)
        let submenu = try #require(openRecent.submenu)
        #expect(submenu.items.count == 1)
        #expect(
            submenu.items[0].title
                == String(localized: "menu.clearMenu")
        )
        #expect(!submenu.items[0].isEnabled)
    }

    @Test("Missing Open Recent item is a safe no-op")
    func missingItemIsNoOp() {
        let target = NativeRecentProjectsMenuTarget()
        #expect(!NativeRecentProjectsMenu.synchronize(
            mainMenu: NSMenu(),
            projects: [],
            target: target,
            openAction:
                #selector(NativeRecentProjectsMenuTarget.openProject(_:)),
            clearAction:
                #selector(NativeRecentProjectsMenuTarget.clearProjects(_:))
        ))
    }
}
