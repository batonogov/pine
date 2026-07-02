//
//  CompletionPopupView.swift
//  Pine
//
//  Phase 3 of LSP support (issue #1012, parent #994).
//
//  SwiftUI popup overlay that renders the filtered completion list and routes
//  keyboard navigation (Up/Down/Enter/Tab/Esc) back to the editor.
//
//  The popup is driven by `CompletionController` (a `@MainActor @Observable`
//  state object) which owns the filtered items, the selection index, and the
//  accept/dismiss callbacks. The controller is created per editor pane in
//  `PaneLeafView`; the popup is layered as a SwiftUI `.overlay` positioned at
//  the caret rect reported by the `NSTextView`.
//

import SwiftUI
import AppKit

/// `@MainActor @Observable` controller for the completion popup.
///
/// Owns the popup's open/closed state, the filtered item list, the selection
/// index, and the editor-side callbacks (accept / dismiss). The editor view
/// calls `present(items:prefix:)` when the LSP server returns completions and
/// `dismiss()` when the user accepts, escapes, or moves the caret outside the
/// current word.
///
/// Marked `@MainActor` because every piece of state it owns drives SwiftUI /
/// AppKit UI and is only ever touched on the main thread.
@MainActor
@Observable
final class CompletionController {

    /// Whether the popup is currently visible.
    private(set) var isVisible: Bool = false

    /// The filtered, ranked items currently shown.
    private(set) var items: [LSPCompletionItem] = []

    /// The index of the highlighted row (0-based). Wraps via `move(by:)`.
    private(set) var selectedIndex: Int = 0

    /// The word prefix that was extracted from the editor when the popup was
    /// presented. Kept so live filtering can re-rank as the user keeps typing.
    private(set) var prefix: String = ""

    /// Called when the user accepts an item. The closure receives the chosen
    /// item; the editor replaces the current word with its `insertText`
    /// (expanding snippets as needed).
    var onAccept: ((LSPCompletionItem) -> Void)?

    /// Called when the user dismisses the popup (Esc, click outside, or caret
    /// movement outside the current word).
    var onDismiss: (() -> Void)?

    /// The full (unfiltered) server list, retained so live re-filtering on
    /// continued typing does not need a new server round-trip.
    private var serverItems: [LSPCompletionItem] = []

    /// Maximum number of items shown in the popup at once. The list scrolls
    /// when the server returns more.
    static let maxVisibleRows = 10

    // MARK: - Presentation

    /// Presents the popup with a freshly fetched server list, filtered by
    /// `prefix`. Re-uses the existing popup if already open (live filtering).
    func present(items serverItems: [LSPCompletionItem], prefix: String) {
        guard !serverItems.isEmpty else {
            dismiss()
            return
        }
        self.serverItems = serverItems
        self.prefix = prefix
        self.items = CompletionFilter.filter(serverItems, prefix: prefix)
        guard !self.items.isEmpty else {
            // No matches after filtering — keep the popup hidden / dismiss it.
            if isVisible { dismiss() }
            return
        }
        // Clamp selection to the new list bounds.
        if selectedIndex >= self.items.count { selectedIndex = 0 }
        isVisible = true
    }

    /// Re-filters the retained server list against a new prefix (the user kept
    /// typing). Cheap — no server round-trip. Dismisses the popup when the new
    /// prefix yields no matches.
    func refine(prefix: String) {
        guard isVisible else { return }
        self.prefix = prefix
        items = CompletionFilter.filter(serverItems, prefix: prefix)
        if items.isEmpty {
            dismiss()
            return
        }
        if selectedIndex >= items.count { selectedIndex = 0 }
    }

    /// Hides the popup and clears state.
    func dismiss() {
        let wasVisible = isVisible
        isVisible = false
        items = []
        serverItems = []
        prefix = ""
        selectedIndex = 0
        if wasVisible { onDismiss?() }
    }

    // MARK: - Keyboard navigation

    /// Moves the selection by `delta` rows, wrapping around the list ends.
    /// `delta` is typically -1 (Up) or +1 (Down).
    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        // Wrap around for snappier navigation at the list ends.
        var newIndex = selectedIndex + delta
        if newIndex < 0 { newIndex = count - 1 }
        if newIndex >= count { newIndex = 0 }
        selectedIndex = newIndex
    }

    /// The currently highlighted item, or `nil` when the list is empty.
    var selectedItem: LSPCompletionItem? {
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    /// Accepts the currently highlighted item, invoking `onAccept`. No-op when
    /// the list is empty.
    func acceptSelected() {
        guard let item = selectedItem else { return }
        let captured = item
        // Dismiss first so the accept callback sees a clean state (e.g. the
        // editor can replace the word without the popup redrawing mid-insert).
        isVisible = false
        items = []
        serverItems = []
        prefix = ""
        selectedIndex = 0
        onAccept?(captured)
    }
}

// MARK: - AppKit popup

/// An AppKit popup layered over the editor's container view, positioned at the
/// caret. Hosts its SwiftUI list content via `NSHostingView` so it inherits
/// Liquid Glass materials and system colors while still being anchorable to a
/// specific `NSRect` inside the `NSTextView`'s coordinate space.
///
/// The popup never becomes first responder — the `GutterTextView` retains
/// keyboard focus and forwards Up/Down/Enter/Tab/Esc to the controller via the
/// coordinator (see `CodeEditorView+Coordinator`). This avoids the
/// focus-fighting that plagues popup implementations on macOS.
@MainActor
final class CompletionPopupContainer: NSView {

    /// The controller driving popup state.
    let controller: CompletionController

    /// The hosting view wrapping the SwiftUI list.
    private let hostingView: NSHostingView<CompletionPopupContent>

    init(controller: CompletionController) {
        self.controller = controller
        // Create the SwiftUI content, bound to the controller. Re-rendering is
        // automatic via @Observable observation.
        self.hostingView = NSHostingView(
            rootView: CompletionPopupContent(controller: controller)
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Positions the popup just below the caret rect (given in the
    /// `EditorContainerView`'s coordinate space) and makes it visible.
    func position(below caretRect: NSRect, in containerWidth: CGFloat) {
        let popupWidth: CGFloat = 320
        // Clamp so the popup stays within the editor bounds horizontally.
        let originX = max(0, min(caretRect.origin.x, containerWidth - popupWidth))
        // Place below the caret line; flip up if there's no room below (the
        // container is a flipped view so origin.y grows downward).
        frame = NSRect(
            x: originX,
            y: max(0, caretRect.maxY + 1),
            width: popupWidth,
            height: Self.estimatedHeight(itemCount: controller.items.count)
        )
        alphaValue = 1
        isHidden = false
    }

    /// Estimates the popup height for `itemCount` rows, capped at the max.
    private static func estimatedHeight(itemCount: Int) -> CGFloat {
        let rows = min(max(itemCount, 1), CompletionController.maxVisibleRows)
        return CGFloat(rows) * Self.rowHeight
    }

    private static let rowHeight: CGFloat = 22
}

// MARK: - SwiftUI popup content

/// The SwiftUI list rendered inside the AppKit popup. Observes
/// `CompletionController` so it re-renders on selection / item changes.
struct CompletionPopupContent: View {
    let controller: CompletionController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                        CompletionRow(
                            item: item,
                            isSelected: index == controller.selectedIndex
                        )
                        .id(index)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.completionPopupList)
            }
            .onChange(of: controller.selectedIndex) { _, newIndex in
                withAnimation(nil) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.completionPopup)
    }
}

/// A single row in the completion popup: kind icon, label (struck-through when
/// deprecated), and detail.
private struct CompletionRow: View {
    let item: LSPCompletionItem
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(item.label)
                .font(.system(size: 12))
                .strikethrough(item.deprecated, color: .primary)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityIdentifier(AccessibilityID.completionItem(item.label))
    }

    private var iconName: String {
        item.kind?.symbolName ?? "questionmark.square"
    }
}
