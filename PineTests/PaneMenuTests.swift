//
//  PaneMenuTests.swift
//  PineTests
//
//  Tests for split pane menu strings, icons, and accessibility identifiers.
//

import Testing
import Foundation
@testable import Pine

struct PaneMenuTests {

    // MARK: - Localized string keys

    @Test func splitRightStringKeyIsDefined() {
        let description = "\(Strings.menuSplitRight)"
        #expect(description.contains("menu.splitRight"))
    }

    @Test func splitDownStringKeyIsDefined() {
        let description = "\(Strings.menuSplitDown)"
        #expect(description.contains("menu.splitDown"))
    }

    @Test func closePaneStringKeyIsDefined() {
        let description = "\(Strings.menuClosePane)"
        #expect(description.contains("menu.closePane"))
    }

    @Test func focusNextPaneStringKeyIsDefined() {
        let description = "\(Strings.menuFocusNextPane)"
        #expect(description.contains("menu.focusNextPane"))
    }

    @Test func focusPreviousPaneStringKeyIsDefined() {
        let description = "\(Strings.menuFocusPreviousPane)"
        #expect(description.contains("menu.focusPreviousPane"))
    }

    // MARK: - Menu icons

    @Test func splitRightIconIsValid() {
        #expect(MenuIcons.splitRight == "rectangle.split.2x1")
    }

    @Test func splitDownIconIsValid() {
        #expect(MenuIcons.splitDown == "rectangle.split.1x2")
    }

    @Test func closePaneIconIsValid() {
        #expect(MenuIcons.closePane == "xmark.rectangle")
    }

    @Test func paneIconsAreDistinct() {
        let icons = [MenuIcons.splitRight, MenuIcons.splitDown, MenuIcons.closePane]
        #expect(Set(icons).count == icons.count)
    }

    // MARK: - Accessibility identifiers

    @Test func paneContainerIdentifierIsDefined() {
        #expect(!AccessibilityID.paneContainer.isEmpty)
        #expect(AccessibilityID.paneContainer == "paneContainer")
    }

    @Test func paneDividerIdentifierIsDefined() {
        #expect(!AccessibilityID.paneDivider.isEmpty)
        #expect(AccessibilityID.paneDivider == "paneDivider")
    }

    @Test func activePaneIndicatorIdentifierIsDefined() {
        #expect(!AccessibilityID.activePaneIndicator.isEmpty)
        #expect(AccessibilityID.activePaneIndicator == "activePaneIndicator")
    }

    @Test func paneAccessibilityIDsAreUnique() {
        let ids = [
            AccessibilityID.paneContainer,
            AccessibilityID.paneDivider,
            AccessibilityID.activePaneIndicator
        ]
        #expect(Set(ids).count == ids.count)
    }

    @Test func paneAccessibilityIDsDoNotCollideWithEditorIDs() {
        let paneIDs = [
            AccessibilityID.paneContainer,
            AccessibilityID.paneDivider,
            AccessibilityID.activePaneIndicator
        ]
        let editorIDs = [
            AccessibilityID.editorArea,
            AccessibilityID.editorTabBar,
            AccessibilityID.codeEditor,
            AccessibilityID.minimap
        ]
        for paneID in paneIDs {
            for editorID in editorIDs {
                #expect(paneID != editorID)
            }
        }
    }

    // MARK: - Notification names

    @Test func splitPaneRightNotificationNameIsDefined() {
        #expect(Notification.Name.splitPaneRight.rawValue == "splitPaneRight")
    }

    @Test func splitPaneDownNotificationNameIsDefined() {
        #expect(Notification.Name.splitPaneDown.rawValue == "splitPaneDown")
    }

    @Test func closePaneNotificationNameIsDefined() {
        #expect(Notification.Name.closePane.rawValue == "closePane")
    }

    @Test func focusNextPaneNotificationNameIsDefined() {
        #expect(Notification.Name.focusNextPane.rawValue == "focusNextPane")
    }

    @Test func focusPreviousPaneNotificationNameIsDefined() {
        #expect(Notification.Name.focusPreviousPane.rawValue == "focusPreviousPane")
    }

    @Test func paneNotificationNamesAreUnique() {
        let names: [Notification.Name] = [
            .splitPaneRight,
            .splitPaneDown,
            .closePane,
            .focusNextPane,
            .focusPreviousPane
        ]
        let rawValues = names.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test func paneNotificationNamesDoNotCollideWithExistingNames() {
        let paneNames: [Notification.Name] = [
            .splitPaneRight,
            .splitPaneDown,
            .closePane,
            .focusNextPane,
            .focusPreviousPane
        ]
        let existingNames: [Notification.Name] = [
            .openFolder,
            .closeTab,
            .toggleComment,
            .findInFile,
            .goToLine,
            .foldCode
        ]
        for paneName in paneNames {
            for existing in existingNames {
                #expect(paneName != existing)
            }
        }
    }
}
