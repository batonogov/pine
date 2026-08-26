//
//  SearchResultsNavigationTests.swift
//  PineTests
//
//  Locks the keyboard-navigation and scroll-reveal policy for project-wide
//  search results (issue #1526).
//
//  The policy under test is the one `AGENTS.md` states for keyboard-first
//  list surfaces: while the selected row is visible the viewport must not
//  move, and once the row leaves the viewport it is revealed by the smallest
//  necessary amount at the nearest edge — never recentered, never animated.
//  An XCUITest that only asserts `isSelected` cannot see scroll geometry, so
//  these tests assert the *request* the view hands to `ScrollViewProxy`.
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

// MARK: - Reveal request policy

@Suite("Search Results Scroll Policy Tests")
struct SearchResultsScrollPolicyTests {

    @Test("Keyboard selection asks for a minimal, unanimated reveal")
    func keyboardSelectionUsesNearestEdge() {
        let request = SearchScrollRequest.keyboardSelection(7)

        #expect(request.index == 7)
        #expect(request.alignment == .nearestEdge)
        #expect(request.motion == .immediate)
    }

    @Test("Keyboard selection never centers the viewport")
    func keyboardSelectionNeverCenters() {
        for index in 0..<25 {
            let request = SearchScrollRequest.keyboardSelection(index)
            #expect(
                request.alignment != .center,
                "Routine navigation must not recenter (AGENTS.md list-surface policy)"
            )
            #expect(
                request.motion != .animated,
                "Routine navigation must not animate (AGENTS.md list-surface policy)"
            )
        }
    }

    @Test("Intentional reveal centers and honors Reduce Motion")
    func intentionalRevealMotionPolicy() {
        #expect(
            SearchScrollRequest.intentionalReveal(3, reduceMotion: false)
                == SearchScrollRequest(
                    index: 3,
                    alignment: .center,
                    motion: .animated
                )
        )
        #expect(
            SearchScrollRequest.intentionalReveal(3, reduceMotion: true)
                == SearchScrollRequest(
                    index: 3,
                    alignment: .center,
                    motion: .immediate
                )
        )
    }

    @Test("Motion resolution collapses to immediate under Reduce Motion")
    func motionResolution() {
        #expect(SearchScrollMotion.resolve(reduceMotion: true) == .immediate)
        #expect(SearchScrollMotion.resolve(reduceMotion: false) == .animated)
    }

    @Test("Minimal reveal passes no anchor to the scroll proxy")
    func nearestEdgeHasNoAnchor() {
        // This is the exact mutation the policy hinges on: handing SwiftUI
        // `.center` here would recenter the viewport on every arrow press.
        #expect(SearchScrollAlignment.nearestEdge.proxyAnchor == nil)
        #expect(SearchScrollAlignment.center.proxyAnchor == .center)
    }

    @Test("Keyboard navigation reaches the proxy with no anchor and no animation")
    func keyboardSelectionReachesProxyUnanchored() {
        // Locks the whole chain the view actually executes: request ->
        // alignment -> proxy anchor, and request -> motion -> withAnimation.
        let request = SearchScrollRequest.keyboardSelection(11)
        #expect(request.alignment.proxyAnchor == nil)
        #expect(!request.motion.usesAnimation)
    }

    @Test("Only animated motion wraps the reveal in withAnimation")
    func motionDrivesAnimation() {
        #expect(SearchScrollMotion.animated.usesAnimation)
        #expect(!SearchScrollMotion.immediate.usesAnimation)
        #expect(!SearchScrollMotion.resolve(reduceMotion: true).usesAnimation)
    }

    @Test("Intentional reveal is centered, and immediate under Reduce Motion")
    func intentionalRevealReachesProxyCentered() {
        let normal = SearchScrollRequest.intentionalReveal(2, reduceMotion: false)
        #expect(normal.alignment.proxyAnchor == .center)
        #expect(normal.motion.usesAnimation)

        let reduced = SearchScrollRequest.intentionalReveal(2, reduceMotion: true)
        #expect(reduced.alignment.proxyAnchor == .center)
        #expect(!reduced.motion.usesAnimation, "Reduce Motion must make the reveal instant")
    }

    @Test("Minimal reveal and centered reveal are distinguishable")
    func alignmentsAreDistinct() {
        // Guards the mutation "make .nearestEdge and .center the same thing":
        // if the two alignments ever collapse, the policy is unenforceable.
        #expect(SearchScrollAlignment.nearestEdge != SearchScrollAlignment.center)
    }
}

// MARK: - Navigation model

@Suite("Search Results Navigation Tests")
@MainActor
struct SearchResultsNavigationTests {

    /// Captures every reveal the model emits. This is the seam that replaces
    /// a live `ScrollViewProxy` — no sleeps, no view host, no polling.
    private final class RevealRecorder {
        private(set) var requests: [SearchScrollRequest] = []

        func attach(to navigation: SearchResultsNavigation) {
            navigation.scrollToIndex = { [self] request in
                requests.append(request)
            }
        }
    }

    private func makeNavigation() -> (SearchResultsNavigation, RevealRecorder) {
        let navigation = SearchResultsNavigation()
        let recorder = RevealRecorder()
        recorder.attach(to: navigation)
        return (navigation, recorder)
    }

    // MARK: Field -> list hand-off

    @Test("Down arrow from the field takes selection into the list")
    func enterListFromField() {
        let (navigation, recorder) = makeNavigation()
        #expect(navigation.focus == .field)
        #expect(navigation.selectedIndex == nil)

        #expect(navigation.enterList(total: 5))

        #expect(navigation.focus == .list)
        #expect(navigation.selectedIndex == 0)
        #expect(recorder.requests == [.keyboardSelection(0)])
    }

    @Test("Entering the list re-reveals the existing selection")
    func enterListRevealsExistingSelection() {
        let (navigation, recorder) = makeNavigation()
        navigation.enterList(total: 10)
        navigation.moveSelection(delta: 4, total: 10)
        navigation.returnFocusToField()

        // The row may have been scrolled off by the mouse while focus sat in
        // the field, so re-entering must reveal it again.
        #expect(navigation.enterList(total: 10))
        #expect(navigation.selectedIndex == 4)
        #expect(recorder.requests.last == .keyboardSelection(4))
    }

    @Test("Down arrow does nothing when there are no results")
    func enterListWithoutResults() {
        let (navigation, recorder) = makeNavigation()

        #expect(!navigation.enterList(total: 0))

        #expect(navigation.focus == .field)
        #expect(navigation.selectedIndex == nil)
        #expect(recorder.requests.isEmpty)
    }

    // MARK: Reveal geometry — the core of #1526

    @Test("Every arrow step asks for a minimal, unanimated reveal")
    func arrowWalkNeverCenters() {
        let total = 40
        let (navigation, recorder) = makeNavigation()
        navigation.enterList(total: total)

        // Walk to the end and back to the top, one row at a time.
        for _ in 0..<(total - 1) {
            navigation.moveSelection(delta: 1, total: total)
        }
        for _ in 0..<(total - 1) {
            navigation.moveSelection(delta: -1, total: total)
        }

        #expect(recorder.requests.count == 2 * total - 1)
        for request in recorder.requests {
            #expect(
                request.alignment == .nearestEdge,
                "Arrow navigation centered the viewport at index \(request.index)"
            )
            #expect(
                request.motion == .immediate,
                "Arrow navigation animated the viewport at index \(request.index)"
            )
        }
    }

    @Test("Selection moves and reveals in lockstep")
    func selectionAndRevealStayInSync() {
        let (navigation, recorder) = makeNavigation()
        navigation.enterList(total: 6)

        navigation.moveSelection(delta: 1, total: 6)
        navigation.moveSelection(delta: 1, total: 6)
        navigation.moveSelection(delta: -1, total: 6)

        #expect(navigation.selectedIndex == 1)
        #expect(recorder.requests.map(\.index) == [0, 1, 2, 1])
    }

    @Test("A row that has not moved is not re-revealed")
    func noRedundantRevealAtBounds() {
        let (navigation, recorder) = makeNavigation()
        navigation.enterList(total: 3)
        let afterEntry = recorder.requests.count

        // Already at the top: Up is a no-op and must not force a layout pass.
        navigation.moveSelection(delta: -1, total: 3)

        #expect(navigation.selectedIndex == 0)
        #expect(recorder.requests.count == afterEntry)
    }

    // MARK: Wrapping

    @Test("Selection clamps at the bounds instead of wrapping")
    func selectionClampsAtBounds() {
        let (navigation, _) = makeNavigation()
        navigation.enterList(total: 4)

        navigation.moveSelection(delta: -1, total: 4)
        #expect(navigation.selectedIndex == 0, "Up at the top must not wrap to the last row")

        for _ in 0..<10 {
            navigation.moveSelection(delta: 1, total: 4)
        }
        #expect(navigation.selectedIndex == 3, "Down at the bottom must not wrap to the first row")
    }

    @Test("Clamped selection index logic")
    func selectionIndexLogic() {
        #expect(SearchSelectionLogic.nextIndex(current: 4, delta: 1, total: 5) == 4)
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: -1, total: 5) == 0)
        #expect(SearchSelectionLogic.nextIndex(current: 2, delta: 1, total: 5) == 3)
        #expect(SearchSelectionLogic.nextIndex(current: 3, delta: -1, total: 5) == 2)
        #expect(SearchSelectionLogic.nextIndex(current: 1, delta: 7, total: 5) == 4)
        #expect(SearchSelectionLogic.nextIndex(current: 3, delta: -7, total: 5) == 0)
        #expect(SearchSelectionLogic.nextIndex(current: nil, delta: 1, total: 5) == 0)
        #expect(SearchSelectionLogic.nextIndex(current: nil, delta: -1, total: 5) == 0)
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: 1, total: 0) == nil)
        #expect(SearchSelectionLogic.nextIndex(current: nil, delta: 1, total: 0) == nil)
        #expect(SearchSelectionLogic.nextIndex(current: 0, delta: 1, total: 1) == 0)
    }

    // MARK: Escape

    @Test("Escape steps out of the list before closing search")
    func escapeStepsOutBeforeClosing() {
        let (navigation, _) = makeNavigation()
        navigation.enterList(total: 5)
        #expect(navigation.focus == .list)

        #expect(navigation.handleEscape() == .returnFocusToField)
        #expect(navigation.focus == .field)

        #expect(navigation.handleEscape() == .dismissSearch)
        #expect(navigation.focus == .field)
    }

    @Test("Escape policy is a pure function of focus")
    func escapePolicy() {
        #expect(SearchKeyboardPolicy.escape(from: .list) == .returnFocusToField)
        #expect(SearchKeyboardPolicy.escape(from: .field) == .dismissSearch)
    }

    // MARK: Mouse and result-set changes

    @Test("Clicking a row selects it without moving the viewport")
    func mouseSelectionDoesNotScroll() {
        let (navigation, recorder) = makeNavigation()

        navigation.select(index: 12)

        #expect(navigation.selectedIndex == 12)
        #expect(navigation.focus == .list)
        #expect(recorder.requests.isEmpty, "A clicked row is already visible")
    }

    @Test("New results reset selection to the top without a reveal")
    func resetOnNewResults() {
        let (navigation, recorder) = makeNavigation()
        navigation.enterList(total: 10)
        navigation.moveSelection(delta: 5, total: 10)
        let beforeReset = recorder.requests.count

        navigation.resetSelection(total: 8)
        #expect(navigation.selectedIndex == 0)
        #expect(recorder.requests.count == beforeReset, "A rebuilt list already renders at the top")

        navigation.resetSelection(total: 0)
        #expect(navigation.selectedIndex == nil)
    }

    @Test("Selection survives only while it is in range")
    func selectionOutOfRangeIsDropped() {
        let (navigation, _) = makeNavigation()
        navigation.enterList(total: 10)
        navigation.moveSelection(delta: 9, total: 10)
        #expect(navigation.selectedIndex == 9)

        navigation.moveSelection(delta: 1, total: 3)
        #expect(navigation.selectedIndex == 2, "Selection must clamp into the shrunken list")
    }
}

// MARK: - Search field hand-off policy

@Suite("Search Field Hand-off Tests")
struct SearchFieldHandoffTests {

    private typealias Key = SearchKeyboardPolicy.KeyCode

    @Test("Down arrow in the field takes the arrows into the list")
    func downArrowEntersList() {
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.downArrow, focus: .field, hasResults: true
        ) == .enterList)
    }

    @Test("Once the list drives, the arrows walk it")
    func arrowsWalkTheList() {
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.downArrow, focus: .list, hasResults: true
        ) == .moveSelection(delta: 1))
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.upArrow, focus: .list, hasResults: true
        ) == .moveSelection(delta: -1))
    }

    @Test("Return opens the selection only once the list drives")
    func returnOpensSelection() {
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.returnKey, focus: .list, hasResults: true
        ) == .openSelected)
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.returnKey, focus: .field, hasResults: true
        ) == .passThrough)
    }

    @Test("Escape steps out of the list before the field sees it")
    func escapeStepsOut() {
        // The regression behind the red CI run: if this passes through, the
        // search field handles Escape and dismisses the whole search.
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.escape, focus: .list, hasResults: true
        ) == .stepOutOfList)
        // Once the field drives again, Escape belongs to it, so search closes.
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.escape, focus: .field, hasResults: true
        ) == .passThrough)
    }

    @Test("Up arrow in the field does not jump to the last row")
    func upArrowInFieldPassesThrough() {
        #expect(SearchKeyboardPolicy.fieldAction(
            keyCode: Key.upArrow, focus: .field, hasResults: true
        ) == .passThrough)
    }

    @Test("Nothing is claimed when there are no results")
    func noResultsClaimsNothing() {
        for focus in [SearchResultsFocus.field, .list] {
            for key in [Key.downArrow, Key.upArrow, Key.returnKey, Key.escape] {
                #expect(SearchKeyboardPolicy.fieldAction(
                    keyCode: key, focus: focus, hasResults: false
                ) == .passThrough)
            }
        }
    }

    @Test("Typing keys are never claimed, so the query stays editable")
    func typingPassesThrough() {
        // Letters, digits, delete, tab, space, arrows left/right.
        for keyCode: UInt16 in [0, 1, 2, 18, 19, 49, 48, 51, 123, 124] {
            for focus in [SearchResultsFocus.field, .list] {
                #expect(SearchKeyboardPolicy.fieldAction(
                    keyCode: keyCode, focus: focus, hasResults: true
                ) == .passThrough, "keyCode \(keyCode) must stay in the field")
            }
        }
    }
}
