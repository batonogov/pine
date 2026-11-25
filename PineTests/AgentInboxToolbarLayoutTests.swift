//
//  AgentInboxToolbarLayoutTests.swift
//  PineTests
//
//  The toolbar pin that keeps the Agent Inbox button in the trailing
//  cluster (#1665).
//

import AppKit
import Testing

@testable import Pine

@Suite("Agent Inbox toolbar layout")
@MainActor
struct AgentInboxToolbarLayoutTests {
    private typealias Layout = AgentInboxToolbarLayout
    private typealias Correction = Layout.Correction

    private func contentItem() -> NSToolbarItem {
        NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(UUID().uuidString))
    }

    private func flex() -> NSToolbarItem {
        NSToolbarItem(itemIdentifier: .flexibleSpace)
    }

    private func search() -> NSToolbarItem {
        NSSearchToolbarItem(itemIdentifier: .init("testSearch"))
    }

    @Test("no flexible space: insert one before the trailing content item")
    func insertsBeforeTrailingContentItem() {
        let pill = contentItem()
        let inbox = contentItem()

        let correction = Layout.correction(in: [pill, inbox, search()])

        #expect(correction == .insertFlexibleSpace(at: 1))
    }

    @Test("the pinned order needs no correction")
    func pinnedOrderIsStable() {
        let items = [contentItem(), flex(), contentItem(), search()]

        #expect(Layout.correction(in: items) == nil)
    }

    @Test("a spacer sorted between the button and the search field is moved")
    func straySpacerMovesBeforeTheButton() {
        // What a declared `ToolbarSpacer` actually produces: SwiftUI sorts it
        // after the primary-action item.
        let items = [contentItem(), contentItem(), flex(), search()]

        let first = Layout.correction(in: items)
        #expect(first == .removeFlexibleSpace(at: 2))

        // After the removal the rule asks for the insertion, then converges.
        let second = Layout.correction(in: [items[0], items[1], items[3]])
        #expect(second == .insertFlexibleSpace(at: 1))
        let pinned = [items[0], items[2], items[1], items[3]]
        #expect(Layout.correction(in: pinned) == nil)
    }

    @Test("duplicate flexible spaces collapse to one")
    func duplicateSpacersCollapse() {
        // What a `Spacer()` in a `ToolbarItem` produces: a flex at the
        // declared position plus a trailing one.
        let items = [contentItem(), flex(), contentItem(), flex(), search()]

        let first = Layout.correction(in: items)
        #expect(first == .removeFlexibleSpace(at: 3))
        let remainder = [items[0], items[1], items[2], items[4]]
        #expect(Layout.correction(in: remainder) == nil)
    }

    // Pine 3.0 R4 removes the search field: without its anchor the rule pins
    // the last content item to the toolbar's own trailing edge.
    @Test("without a search field the last content item is pinned")
    func noSearchFieldPinsTrailingEdge() {
        #expect(
            Layout.correction(in: [contentItem(), contentItem()])
                == .insertFlexibleSpace(at: 1)
        )
        #expect(
            Layout.correction(in: [contentItem()]) == .insertFlexibleSpace(at: 0)
        )
        #expect(Layout.correction(in: []) == nil)
        #expect(Layout.correction(in: [flex()]) == nil)
        #expect(Layout.correction(in: [flex(), contentItem()]) == nil)
    }

    @Test("a stray trailing flexible space is removed without a search field")
    func noSearchFieldStrayTrailingFlex() {
        // [pill, button, flex] — a declared spacer's trailing flex.
        let items = [contentItem(), contentItem(), flex()]
        #expect(Layout.correction(in: items) == .removeFlexibleSpace(at: 2))
        #expect(Layout.correction(in: [items[0], items[1]])
            == .insertFlexibleSpace(at: 1)
        )
        #expect(Layout.correction(in: [items[0], flex(), items[1]]) == nil)
    }

    /// The pin loop against a real NSToolbar — duplicate `.flexibleSpace`
    /// identifiers are legal precisely because AppKit vends a fresh instance
    /// per insertion, which this exercises end to end.
    @Test("pinning a real toolbar converges to the trailing cluster")
    func pinRealToolbarConverges() throws {
        final class Delegate: NSObject, NSToolbarDelegate {
            func toolbar(
                _ toolbar: NSToolbar,
                itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                willBeInsertedIntoToolbar flag: Bool
            ) -> NSToolbarItem? {
                if itemIdentifier.rawValue == "testSearch" {
                    return NSSearchToolbarItem(itemIdentifier: itemIdentifier)
                }
                return NSToolbarItem(itemIdentifier: itemIdentifier)
            }

            func toolbarDefaultItemIdentifiers(
                _ toolbar: NSToolbar
            ) -> [NSToolbarItem.Identifier] { [] }

            func toolbarAllowedItemIdentifiers(
                _ toolbar: NSToolbar
            ) -> [NSToolbarItem.Identifier] { [] }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        let toolbar = NSToolbar(identifier: "test")
        let delegate = Delegate()
        toolbar.delegate = delegate
        window.toolbar = toolbar
        // SwiftUI's own order: pill, inbox, search — no flexible space.
        toolbar.insertItem(withItemIdentifier: .init("pill"), at: 0)
        toolbar.insertItem(withItemIdentifier: .init("inbox"), at: 1)
        toolbar.insertItem(withItemIdentifier: .init("testSearch"), at: 2)

        Layout.pin(toolbar: toolbar)

        let identifiers = toolbar.items.map(\.itemIdentifier)
        #expect(identifiers == [
            .init("pill"), .flexibleSpace, .init("inbox"), .init("testSearch")
        ])

        // Idempotent: pinning again changes nothing.
        Layout.pin(toolbar: toolbar)
        #expect(toolbar.items.map(\.itemIdentifier) == identifiers)

        // R4's toolbar has no search field: the pin falls back to the
        // toolbar's own trailing edge.
        let r4Window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        let r4Toolbar = NSToolbar(identifier: "testR4")
        r4Toolbar.delegate = delegate
        r4Window.toolbar = r4Toolbar
        r4Toolbar.insertItem(withItemIdentifier: .init("pill"), at: 0)
        r4Toolbar.insertItem(withItemIdentifier: .init("inbox"), at: 1)

        Layout.pin(toolbar: r4Toolbar)

        let r4Identifiers = r4Toolbar.items.map(\.itemIdentifier)
        #expect(r4Identifiers == [.init("pill"), .flexibleSpace, .init("inbox")])
        Layout.pin(toolbar: r4Toolbar)
        #expect(r4Toolbar.items.map(\.itemIdentifier) == r4Identifiers)
        withExtendedLifetime(delegate) {}
        withExtendedLifetime(r4Window) {}
    }
}
