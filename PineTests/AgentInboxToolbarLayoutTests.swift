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

    @Test("a toolbar without a search field is left alone")
    func noSearchFieldNoCorrection() {
        #expect(Layout.correction(in: [contentItem(), contentItem()]) == nil)
        #expect(Layout.correction(in: []) == nil)
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
        withExtendedLifetime(delegate) {}
    }
}
