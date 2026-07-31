//
//  NativeRecentProjectsMenu.swift
//  Pine
//
//  Keeps File > Open Recent truthful after its SwiftUI Menu has been
//  materialized as an AppKit submenu.
//

import AppKit

@MainActor
enum NativeRecentProjectsMenu {
    @discardableResult
    static func synchronize(
        mainMenu: NSMenu?,
        projects: [URL],
        target: AnyObject,
        openAction: Selector,
        clearAction: Selector
    ) -> Bool {
        guard let openRecentItem = findOpenRecentItem(in: mainMenu) else {
            return false
        }

        let submenu = openRecentItem.submenu ?? NSMenu()
        openRecentItem.submenu = submenu
        submenu.removeAllItems()

        for projectURL in projects {
            let item = NSMenuItem(
                title: ProjectRegistry.recentProjectDisplayTitle(
                    for: projectURL
                ),
                action: openAction,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = projectURL
            submenu.addItem(item)
        }

        if !projects.isEmpty {
            submenu.addItem(.separator())
        }

        let clearItem = NSMenuItem(
            title: String(localized: "menu.clearMenu"),
            action: clearAction,
            keyEquivalent: ""
        )
        clearItem.target = target
        clearItem.isEnabled = !projects.isEmpty
        clearItem.image = NSImage(
            systemSymbolName: MenuIcons.clearMenu,
            accessibilityDescription: nil
        )
        submenu.addItem(clearItem)

        openRecentItem.isEnabled = !projects.isEmpty
        return true
    }

    private static func findOpenRecentItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        let title = String(localized: "menu.openRecent")
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let nested = findOpenRecentItem(in: item.submenu) {
                return nested
            }
        }
        return nil
    }
}
