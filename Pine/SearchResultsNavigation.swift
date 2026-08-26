//
//  SearchResultsNavigation.swift
//  Pine
//
//  Keyboard navigation and scroll-reveal policy for project-wide search
//  results (issue #1526).
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Scroll reveal policy

/// Whether a reveal animates.
///
/// Mirrors ``SidebarScrollMotion`` so every keyboard-first list surface in
/// Pine obeys one policy instead of drifting apart.
enum SearchScrollMotion: Equatable, Sendable {
    case animated
    case immediate

    static func resolve(reduceMotion: Bool) -> Self {
        reduceMotion ? .immediate : .animated
    }

    /// Whether the reveal should be wrapped in `withAnimation`.
    /// Kept here rather than branched at the call site so the policy stays
    /// verifiable without a view host.
    var usesAnimation: Bool {
        self == .animated
    }
}

/// Where a revealed row is allowed to land in the viewport.
enum SearchScrollAlignment: Equatable, Sendable {
    /// Let SwiftUI move the smallest amount needed to reveal the row, leaving
    /// the viewport untouched while the row is already visible.
    /// Maps to `ScrollViewProxy.scrollTo(id)` with **no** anchor.
    case nearestEdge
    /// Deliberately place the row in the middle of the viewport.
    /// Maps to `ScrollViewProxy.scrollTo(id, anchor: .center)`.
    case center

    /// The anchor to hand `ScrollViewProxy.scrollTo(_:anchor:)`.
    ///
    /// `nil` is the minimal-shift reveal: with no anchor SwiftUI leaves the
    /// viewport alone while the row is visible and otherwise moves it by the
    /// smallest amount that brings the row to the nearest edge. Returning
    /// `.center` here for `nearestEdge` would silently recenter every arrow
    /// press, which is exactly what `AGENTS.md` forbids — so this mapping is
    /// the single place the policy is expressed, and it is unit-tested.
    var proxyAnchor: UnitPoint? {
        switch self {
        case .nearestEdge:
            return nil
        case .center:
            return .center
        }
    }
}

/// A request to reveal one result row.
///
/// `AGENTS.md` states the policy for keyboard-first list surfaces: while the
/// selected row is visible the viewport must not move, and once the row
/// leaves the viewport it is revealed by the smallest necessary amount at the
/// nearest edge — never recentered, never animated. `.center` and animation
/// are reserved for an intentional reveal, and must become immediate under
/// Reduce Motion.
struct SearchScrollRequest: Equatable, Sendable {
    let index: Int
    let alignment: SearchScrollAlignment
    let motion: SearchScrollMotion

    /// Routine arrow-key navigation: minimal shift, never centered, never
    /// animated.
    static func keyboardSelection(_ index: Int) -> Self {
        Self(index: index, alignment: .nearestEdge, motion: .immediate)
    }

    /// Intentional reveal. Centering is allowed here, and collapses to an
    /// immediate jump under Reduce Motion.
    static func intentionalReveal(_ index: Int, reduceMotion: Bool) -> Self {
        Self(
            index: index,
            alignment: .center,
            motion: .resolve(reduceMotion: reduceMotion)
        )
    }
}

// MARK: - Focus policy

/// Which surface of the search panel owns the navigation keys.
///
/// This is deliberately *not* AppKit first responder. The toolbar search
/// field keeps the caret the whole time, the way Spotlight and Safari's
/// find bar behave, so the user can keep refining the query while arrowing
/// through results. `list` means "the results list is driving the arrow
/// keys", not "the list is first responder" — see
/// ``SearchFieldHandoffMonitor`` for why first responder cannot be moved.
enum SearchResultsFocus: Equatable, Sendable {
    case field
    case list
}

/// What Escape does, given where focus currently sits.
enum SearchEscapeOutcome: Equatable, Sendable {
    /// Escape in the list steps back to the field it came from.
    case returnFocusToField
    /// Escape in the field closes the search panel.
    case dismissSearch
}

/// What a key pressed while the caret is in the search field should do.
enum SearchFieldKeyAction: Equatable, Sendable {
    /// Down with nothing selected yet: take the arrow keys into the list.
    case enterList
    case moveSelection(delta: Int)
    case openSelected
    /// Escape while the list drives the arrows: give them back to the field.
    case stepOutOfList
    /// Leave the event to the field, so typing and editing are untouched.
    case passThrough
}

/// Pure keyboard policy for the search panel, extracted for testability.
enum SearchKeyboardPolicy {
    enum KeyCode {
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        static let returnKey: UInt16 = 36
        static let escape: UInt16 = 53
    }

    static func escape(from focus: SearchResultsFocus) -> SearchEscapeOutcome {
        switch focus {
        case .list:
            return .returnFocusToField
        case .field:
            return .dismissSearch
        }
    }

    /// Maps a key pressed in the search field to a list action.
    ///
    /// Every key that is not explicitly claimed passes through, so typing,
    /// caret movement, and text editing in the field keep working. With no
    /// results nothing is claimed at all.
    static func fieldAction(
        keyCode: UInt16,
        focus: SearchResultsFocus,
        hasResults: Bool
    ) -> SearchFieldKeyAction {
        guard hasResults else { return .passThrough }
        switch (keyCode, focus) {
        case (KeyCode.downArrow, .field):
            return .enterList
        case (KeyCode.downArrow, .list):
            return .moveSelection(delta: 1)
        case (KeyCode.upArrow, .list):
            return .moveSelection(delta: -1)
        case (KeyCode.returnKey, .list):
            return .openSelected
        case (KeyCode.escape, .list):
            return .stepOutOfList
        default:
            return .passThrough
        }
    }
}

// MARK: - Navigation model

/// Owns selection and reveal for the project search results list.
///
/// The reveal sink is a closure rather than a direct `ScrollViewProxy` call so
/// the policy can be tested without a view host: tests substitute a capturing
/// closure and assert the exact requests, which is the only way to verify
/// scroll geometry — an XCUITest that asserts `isSelected` cannot see it.
@MainActor
@Observable
final class SearchResultsNavigation {
    private(set) var selectedIndex: Int?
    private(set) var focus: SearchResultsFocus = .field

    /// Wired to the `ScrollViewProxy` by ``SearchResultsView``.
    @ObservationIgnored
    var scrollToIndex: ((SearchScrollRequest) -> Void)?

    /// Down arrow from the search field: take selection into the list.
    ///
    /// Always re-reveals, because the row may have been scrolled off by the
    /// mouse while focus sat in the field.
    @discardableResult
    func enterList(total: Int) -> Bool {
        guard total > 0 else { return false }
        focus = .list
        let target = min(selectedIndex ?? 0, total - 1)
        selectedIndex = target
        scrollToIndex?(.keyboardSelection(target))
        return true
    }

    /// Up/Down within the list. Clamps at the bounds — wrapping would move the
    /// selection past the edge of the viewport with nothing to explain it.
    func moveSelection(delta: Int, total: Int) {
        guard let next = SearchSelectionLogic.nextIndex(
            current: selectedIndex,
            delta: delta,
            total: total
        ) else {
            selectedIndex = nil
            return
        }
        focus = .list
        // A row that has not moved is already visible; re-revealing it only
        // forces another layout pass.
        guard next != selectedIndex else { return }
        selectedIndex = next
        scrollToIndex?(.keyboardSelection(next))
    }

    /// Mouse selection. The clicked row is by definition visible, so this does
    /// not move the viewport.
    func select(index: Int) {
        selectedIndex = index
        focus = .list
    }

    func returnFocusToField() {
        focus = .field
    }

    @discardableResult
    func handleEscape() -> SearchEscapeOutcome {
        let outcome = SearchKeyboardPolicy.escape(from: focus)
        if outcome == .returnFocusToField {
            focus = .field
        }
        return outcome
    }

    /// A new result set replaced the old one. The rebuilt list already renders
    /// at the top, so this deliberately issues no reveal.
    func resetSelection(total: Int) {
        selectedIndex = total == 0 ? nil : 0
    }
}

// MARK: - Toolbar search field bridge

/// Bridges the toolbar search field to the results list.
///
/// The field is an `NSSearchToolbarItem` created by `.searchable`, so it lives
/// in the window toolbar rather than in `SearchResultsView`'s SwiftUI
/// hierarchy — `onKeyPress` never sees its key events. A local key monitor,
/// live only while results are on screen, gives Down arrow the hand-off the
/// HIG expects without taking over the field's delegate.
///
/// ## Why the caret stays in the field
///
/// An earlier version of this moved SwiftUI `@FocusState` to the results list
/// on Down and let `.onKeyPress` handle the arrows and Escape. It does not
/// work: setting `@FocusState` does not win AppKit first responder away from
/// the toolbar's `NSSearchField`, which re-activates itself (see the note on
/// `SidebarKeyboardFocusController.focusRetryDelays` about "the later AppKit
/// activation used by an expanded search toolbar item"). Selection moved
/// because the model was mutated directly, but the `.onKeyPress` handlers
/// never ran, so Escape reached the field and dismissed the whole search —
/// caught by `testEscapeFromResultsReturnsFocusToSearchField`.
///
/// So the caret deliberately stays in the field and this monitor owns the
/// navigation keys, which is also how Spotlight and Safari's find bar behave:
/// the query stays editable while the arrows drive the list. `.onKeyPress` on
/// the list remains for the case where the user clicks into it and SwiftUI
/// focus really is there; both paths funnel through
/// ``SearchResultsNavigation``.
///
/// ## Why not the SwiftUI path
///
/// This is deliberately AppKit, and the SwiftUI alternatives were considered
/// and rejected — do not "modernize" it without re-checking the following:
///
/// - `.searchFocused(_:)` only *moves* focus into or out of the search field.
///   It reports and sets focus; it does not deliver key events, so it cannot
///   tell us that Down was pressed **while the caret is in the field**. It
///   solves the wrong half of the problem.
/// - `.onKeyPress` on any view in `SearchResultsView` or its ancestors never
///   fires for the field, because `NSSearchToolbarItem` is hosted by the
///   window's `NSToolbar`, outside this view tree. Attaching it to the
///   `.searchable` modifier in `ProjectSearchModifier` does not help either:
///   the modifier annotates the content view, not the toolbar item AppKit
///   creates from it.
/// - Giving the field an `NSTextFieldDelegate` (the `QuickOpenSearchField`
///   approach, which does work for the Cmd+P overlay) would mean owning a
///   field that SwiftUI created and still drives through its `text` binding.
///   Quick Open owns its `NSTextField` outright; here we do not.
///
/// ## When this can be replaced
///
/// Drop this class the moment SwiftUI exposes key handling for the search
/// field itself — an `onKeyPress`-style hook on `.searchable`, or a
/// `searchable` variant that vends the underlying field. At that point the
/// replacement must still route through ``SearchKeyboardPolicy``, which is
/// where the rules actually live and are unit-tested; only the event
/// *plumbing* below is AppKit-specific. Moving first responder into the list
/// is **not** a prerequisite and should not be attempted — see above.
@MainActor
final class SearchFieldHandoffMonitor {
    private var monitor: Any?

    /// Whether the results list currently has anything to select.
    var hasResults: (() -> Bool)?

    /// Which surface currently owns the navigation keys.
    var currentFocus: (() -> SearchResultsFocus)?

    /// Performs the action. Returns `true` when it was consumed, which stops
    /// the event from reaching the search field.
    var onAction: ((SearchFieldKeyAction) -> Bool)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .option, .control, .shift]) else {
            return false
        }
        guard Self.isSearchFieldFocused(in: event.window) else { return false }
        let action = SearchKeyboardPolicy.fieldAction(
            keyCode: event.keyCode,
            focus: currentFocus?() ?? .field,
            hasResults: hasResults?() ?? false
        )
        guard action != .passThrough else { return false }
        return onAction?(action) ?? false
    }

    /// True when the window's first responder is the field editor of the
    /// toolbar search field.
    static func isSearchFieldFocused(in window: NSWindow?) -> Bool {
        guard let window,
              let searchField = searchField(in: window) else { return false }
        guard let responder = window.firstResponder else { return false }
        if responder === searchField { return true }
        // While editing, the first responder is the shared field editor whose
        // delegate is the search field.
        if let textView = responder as? NSTextView {
            return textView.delegate === searchField
        }
        return false
    }

    /// Moves keyboard focus back into the toolbar search field.
    @discardableResult
    static func focusSearchField(in window: NSWindow?) -> Bool {
        guard let window,
              let item = searchToolbarItem(in: window) else { return false }
        item.beginSearchInteraction()
        return true
    }

    private static func searchToolbarItem(in window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.lazy
            .compactMap { $0 as? NSSearchToolbarItem }
            .first
    }

    private static func searchField(in window: NSWindow) -> NSSearchField? {
        searchToolbarItem(in: window)?.searchField
    }
}
