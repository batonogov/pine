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
                onArrowUp: { moveSelection(by: -1) },
                onArrowDown: { moveSelection(by: 1) },
                onReturn: { openSelected() },
                onEscape: { isPresented = false }
            )
            .accessibilityIdentifier(AccessibilityID.quickOpenSearchField)
            .padding(10)

            Divider()
            resultsList
        }
        .frame(width: 500, height: 360)
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
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
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
                .foregroundStyle(.secondary)
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
        projectManager.tabManager.openTab(url: url)
        isPresented = false
    }
}

// MARK: - AppKit Search Field with key interception

/// NSTextField wrapper that intercepts arrow keys, Return, and Escape
/// before the text field processes them — SwiftUI's `.onKeyPress` on
/// TextField does not reliably capture these keys on macOS.
struct QuickOpenSearchField: NSViewRepresentable {
    @Binding var text: String
    var onArrowUp: () -> Void
    var onArrowDown: () -> Void
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = KeyInterceptingTextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: 14)
        field.placeholderString = String(localized: "quickOpen.placeholder")
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.onArrowUp = onArrowUp
        field.onArrowDown = onArrowDown
        field.onReturn = onReturn
        field.onEscape = onEscape
        // Become first responder on next run loop to ensure the field is in window
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if let field = nsView as? KeyInterceptingTextField {
            field.onArrowUp = onArrowUp
            field.onArrowDown = onArrowDown
            field.onReturn = onReturn
            field.onEscape = onEscape
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }
    }
}

/// NSTextField subclass that overrides key event handling to intercept
/// arrow keys, Return, and Escape before the standard field editor processes them.
private final class KeyInterceptingTextField: NSTextField {
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        switch Int(event.keyCode) {
        case 126: // Up arrow
            onArrowUp?()
            return true
        case 125: // Down arrow
            onArrowDown?()
            return true
        case 36: // Return
            onReturn?()
            return true
        case 53: // Escape
            onEscape?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
