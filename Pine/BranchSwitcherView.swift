//
//  BranchSwitcherView.swift
//  Pine
//

import SwiftUI

struct BranchSwitcherView: View {
    var gitProvider: GitStatusProvider
    @Binding var isPresented: Bool
    var projectManager: ProjectManager? = nil
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var errorMessage = ""
    @FocusState private var isListFocused: Bool

    /// Pure keyboard state. Every key the switcher handles is resolved through
    /// this value so cancellation can never fall through to a checkout (#1522).
    private var selection: BranchSwitcherSelection {
        BranchSwitcherSelection(
            branches: gitProvider.branches,
            filter: searchText,
            selectedIndex: selectedIndex
        )
    }

    private var filteredBranches: [String] { selection.filteredBranches }

    var body: some View {
        VStack(spacing: 0) {
            QuickOpenSearchField(
                text: $searchText,
                placeholder: Strings.branchFilterPlaceholder,
                accessibility: CommandOverlayTextFieldAccessibility(
                    identifier: AccessibilityID.branchSearchField,
                    label: Strings.branchFilterPlaceholder
                ),
                onArrowUp: { handle(.up) },
                onArrowDown: { handle(.down) },
                onReturn: { handle(.activate) },
                onEscape: { handle(.cancel) },
                onTab: { isListFocused = true }
            )
            .padding(8)

            Divider()

            branchList

            if !errorMessage.isEmpty {
                Divider()
                BranchSwitcherErrorRow(message: errorMessage)
                    .padding(8)
                    .transition(PineAnimation.fadeTransition)
            }

            Divider()

            HStack {
                Spacer()
                Button(Strings.branchSwitcherCancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.branchCancelButton)
            }
            .padding(8)
        }
        .frame(width: 280)
        .onChange(of: searchText) { _, _ in
            // The visible rows just changed underneath the cursor; start over
            // at the top rather than leaving a stale row selected.
            selectedIndex = 0
        }
        // Escape must work from any focus position, including the rows and the
        // Cancel button, not just the filter field.
        .onExitCommand { cancel() }
        .animation(PineAnimation.quick, value: errorMessage.isEmpty)
    }

    // MARK: - Branch list

    private var branchList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(filteredBranches.enumerated()),
                        id: \.element
                    ) { index, branch in
                        Button {
                            selectedIndex = index
                            switchToBranch(branch)
                        } label: {
                            branchRow(
                                branch,
                                isSelected: selection.isSelected(index: index)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityIdentifier(AccessibilityID.branchItem(branch))
                        .accessibilityHint(Strings.a11yBranchSwitcherHint)
                        .modifier(
                            BranchRowSelectionAccessibility(
                                isSelected: selection.isSelected(index: index),
                                isCurrent: branch == gitProvider.currentBranch
                            )
                        )
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                proxy.scrollTo(newIndex, anchor: .center)
            }
        }
        .frame(maxHeight: 300)
        // Tab moves focus here from the filter field; the list then owns the
        // same four keys so navigation does not depend on where focus landed.
        .focusable()
        .focused($isListFocused)
        .onKeyPress(.upArrow) { handle(.up); return .handled }
        .onKeyPress(.downArrow) { handle(.down); return .handled }
        .onKeyPress(.return) { handle(.activate); return .handled }
        .onKeyPress(.escape) { handle(.cancel); return .handled }
        .accessibilityIdentifier(AccessibilityID.branchList)
    }

    private func branchRow(_ branch: String, isSelected: Bool) -> some View {
        let isCurrent = branch == gitProvider.currentBranch
        return HStack {
            Image(systemName: isCurrent
                  ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? .green : .secondary)
                .frame(width: 16)
                // Decorative. Left visible to AX, the checkmark glyph makes
                // AppKit report the row as selected, which would collide with
                // the keyboard selection the same trait must carry.
                .accessibilityHidden(true)
            Text(branch)
                .font(.system(size: 12))
                .foregroundStyle(isCurrent ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Key handling

    private func handle(_ key: BranchSwitcherSelection.Key) {
        switch selection.action(for: key) {
        case .none:
            break
        case .move(let index):
            selectedIndex = index
        case .checkout(let branch):
            switchToBranch(branch)
        case .dismiss:
            cancel()
        }
    }

    /// Closes the switcher without touching the working tree. The single exit
    /// that Escape and the Cancel button share.
    private func cancel() {
        errorMessage = ""
        isPresented = false
    }

    private func switchToBranch(_ branch: String) {
        guard branch != gitProvider.currentBranch else {
            isPresented = false
            return
        }

        let context = if let projectManager {
            DialogPresenter.forProject(projectManager)
        } else {
            DialogPresentationContext.unscoped
        }
        Task { @MainActor in
            guard context.nsWindow?.isVisible == true else { return }
            if gitProvider.hasUncommittedChanges {
                // A native alert cannot attach while this switcher itself is
                // a SwiftUI sheet. Dismiss the switcher first; the per-window
                // coordinator will start the alert after AppKit reports that
                // the framework-owned sheet has ended.
                isPresented = false
                guard await AlertTemplate.branchUncommittedChanges.runSheet(
                    on: context,
                    messageText: Strings.branchUncommittedChangesTitle,
                    informativeText: Strings.branchUncommittedChangesMessage(branch)
                ) == .alertFirstButtonReturn else { return }
                guard context.nsWindow?.isVisible == true else { return }
            } else {
                // Keep checkout failures presentable as native sheets without
                // nesting beneath the switcher's framework-owned sheet.
                isPresented = false
            }

            let result = await gitProvider.checkoutBranchAsync(branch)
            if result.success {
                errorMessage = ""
                isPresented = false
            } else {
                errorMessage = result.error
                _ = await AlertTemplate.fileOperationErrorWarning.runSheet(
                    on: context,
                    messageText: Strings.branchSwitchErrorTitle,
                    informativeText: result.error
                )
            }
        }
    }
}

/// Keeps "this is the branch you are on" and "this is the row the arrow keys
/// are on" as two distinct things for VoiceOver: only the keyboard selection
/// carries `.isSelected`, and the trait is removed rather than merely
/// not-added on every other row (#1522).
private struct BranchRowSelectionAccessibility: ViewModifier {
    let isSelected: Bool
    let isCurrent: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(
                CommandOverlayRowAccessibility.selectionTraits(
                    isSelected: isSelected
                )
            )
            .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
            .accessibilityValue(
                isCurrent ? Text(Strings.branchCurrentAccessibilityValue) : Text("")
            )
    }
}

/// The checkout-failure footer. The symbol pairs with the message so the
/// error state is never carried by the red hue alone (#1540) — the same
/// distinct-SF-Symbol-per-level pattern the Problems panel uses. The message
/// text already announces the failure, so the glyph stays decorative.
struct BranchSwitcherErrorRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }
}
