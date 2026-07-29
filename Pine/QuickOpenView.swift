//
//  QuickOpenView.swift
//  Pine
//
//  Quick Open overlay for fuzzy file search (Cmd+P).
//

import SwiftUI

struct QuickOpenView: View {
    @Environment(ProjectManager.self) var projectManager
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var results: [QuickOpenProvider.Result] = []
    @State private var searchTask: Task<Void, Never>?

    private var provider: QuickOpenProvider { projectManager.quickOpenProvider }

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenSearchField(
                text: $searchText,
                accessibility: CommandOverlayTextFieldAccessibility(
                    identifier: AccessibilityID.quickOpenSearchField,
                    label: String(localized: "quickOpen.placeholder")
                ),
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onReturn: { openSelected() },
                onEscape: { isPresented = false }
            )
            .padding(10)

            Divider()
            resultsList
        }
        .frame(
            minWidth: 300,
            idealWidth: 500,
            maxWidth: 500,
            minHeight: 220,
            idealHeight: 360,
            maxHeight: 360
        )
        .onAppear {
            provider.buildIndex(
                from: projectManager.rootNodes,
                rootURL: projectManager.rootURL ?? URL(fileURLWithPath: "/")
            )
            updateResults()
        }
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .accessibilityIdentifier(AccessibilityID.quickOpenOverlay)
    }

    // MARK: - Results List

    private var resultsList: some View {
        Group {
            if results.isEmpty {
                emptyState
                    .transition(PineAnimation.fadeTransition)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                resultRow(result, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        selectedIndex = index
                                        openFile(result.url)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction {
                                        selectedIndex = index
                                        openFile(result.url)
                                    }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .animation(PineAnimation.content, value: results.isEmpty)
        .accessibilityIdentifier(AccessibilityID.quickOpenResultsList)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if searchText.isEmpty {
                Text(Strings.quickOpenRecentEmpty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text(Strings.quickOpenNoResults)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func resultRow(_ result: QuickOpenProvider.Result, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileIconMapper.iconForFile(result.fileName))
                .font(.system(size: 14))
                .foregroundStyle(FileIconMapper.colorForFile(result.fileName))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.fileName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(result.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier(AccessibilityID.quickOpenItem(result.fileName))
    }

    // MARK: - Actions

    private func scheduleSearch() {
        searchTask?.cancel()
        if searchText.isEmpty {
            updateResults()
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            updateResults()
        }
    }

    private func updateResults() {
        results = provider.search(query: searchText)
        selectedIndex = 0
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func openSelected() {
        guard selectedIndex < results.count else { return }
        openFile(results[selectedIndex].url)
    }

    private func openFile(_ url: URL) {
        provider.recordOpened(url: url)
        projectManager.paneManager.openFileInActiveEditor(url: url)
        isPresented = false
    }
}

// MARK: - AppKit Search Field with key interception

/// NSTextField wrapper that intercepts arrow keys, Return, and Escape
/// via the delegate's `control(_:textView:doCommandBy:)` method.
/// This preserves the normal text cursor and field editor behavior
/// while redirecting navigation keys to the Quick Open list.
struct CommandOverlayTextFieldAccessibility: Equatable {
    let identifier: String
    let label: String?
    let help: String?

    init(
        identifier: String,
        label: String? = nil,
        help: String? = nil
    ) {
        self.identifier = identifier
        self.label = label
        self.help = help
    }
}

/// Native field shared by command overlays.
///
/// SwiftUI accessibility modifiers applied to an `NSViewRepresentable` do not
/// reliably reach its underlying AppKit view when it is hosted in a separate
/// `NSPanel`. Configure the native element directly and request first responder
/// only after AppKit has attached it to a window.
@MainActor
final class CommandOverlayTextField: NSTextField {
    private static let maximumFocusAttempts = 2

    private weak var focusWindow: NSWindow?
    private var focusAttemptCount = 0
    private var focusAttemptScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if focusWindow !== window {
            focusWindow = window
            focusAttemptCount = 0
            focusAttemptScheduled = false
        }
        requestInitialFocus()
    }

    func applyAccessibility(
        _ accessibility: CommandOverlayTextFieldAccessibility
    ) {
        // `NSTextField` normally derives its accessibility exposure from its
        // cell. SwiftUI's `NSViewRepresentable` host can suppress that
        // implicit element on macOS 26 when the view lives in an NSPanel:
        // the panel/container remains visible to AX, but the represented
        // field is omitted from its descendants. Declare the native contract
        // explicitly so VoiceOver and role-scoped XCUITest queries see the
        // field as an editable text field on both macOS 26 and 27.
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        identifier = NSUserInterfaceItemIdentifier(
            accessibility.identifier
        )
        setAccessibilityIdentifier(accessibility.identifier)
        setAccessibilityLabel(accessibility.label)
        setAccessibilityHelp(accessibility.help)
    }

    /// Schedules focus after the current AppKit/SwiftUI attachment transaction.
    ///
    /// The command panel also invokes this after becoming key. Coalescing both
    /// lifecycle paths avoids races without repeatedly stealing focus while a
    /// user edits the field.
    func requestInitialFocus() {
        guard window != nil else { return }
        guard focusAttemptCount < Self.maximumFocusAttempts else { return }
        guard !focusAttemptScheduled else { return }

        focusAttemptScheduled = true
        let expectedWindow = window
        DispatchQueue.main.async { [weak self, weak expectedWindow] in
            guard let self else { return }
            self.focusAttemptScheduled = false
            guard let expectedWindow,
                  self.window === expectedWindow else { return }

            self.focusAttemptCount += 1
            if !expectedWindow.makeFirstResponder(self) {
                self.requestInitialFocus()
            }
        }
    }
}

struct QuickOpenSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = String(localized: "quickOpen.placeholder")
    let accessibility: CommandOverlayTextFieldAccessibility
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> CommandOverlayTextField {
        let field = CommandOverlayTextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.cell?.sendsActionOnEndEditing = false
        field.applyAccessibility(accessibility)
        return field
    }

    func updateNSView(
        _ nsView: CommandOverlayTextField,
        context: Context
    ) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.applyAccessibility(accessibility)
        // Keep callbacks up to date
        context.coordinator.onArrowUp = onArrowUp
        context.coordinator.onArrowDown = onArrowDown
        context.coordinator.onReturn = onReturn
        context.coordinator.onEscape = onEscape
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onArrowUp: onArrowUp,
            onArrowDown: onArrowDown,
            onReturn: onReturn,
            onEscape: onEscape
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onArrowUp: () -> Void
        var onArrowDown: () -> Void
        var onReturn: () -> Void
        var onEscape: () -> Void

        init(
            text: Binding<String>,
            onArrowUp: @escaping () -> Void,
            onArrowDown: @escaping () -> Void,
            onReturn: @escaping () -> Void,
            onEscape: @escaping () -> Void
        ) {
            _text = text
            self.onArrowUp = onArrowUp
            self.onArrowDown = onArrowDown
            self.onReturn = onReturn
            self.onEscape = onEscape
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                onArrowUp()
                return true
            case #selector(NSResponder.moveDown(_:)):
                onArrowDown()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                onReturn()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onEscape()
                return true
            default:
                return false
            }
        }
    }
}
