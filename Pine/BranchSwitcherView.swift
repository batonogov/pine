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
    @State private var errorMessage = ""

    private var filteredBranches: [String] {
        if searchText.isEmpty { return gitProvider.branches }
        return gitProvider.branches.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(Strings.branchFilterPlaceholder, text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .accessibilityIdentifier(AccessibilityID.branchSearchField)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredBranches, id: \.self) { branch in
                        Button {
                            switchToBranch(branch)
                        } label: {
                            HStack {
                                Image(systemName: branch == gitProvider.currentBranch
                                      ? "checkmark.circle.fill" : "arrow.triangle.branch")
                                    .font(.system(size: 11))
                                    .foregroundStyle(branch == gitProvider.currentBranch ? .green : .secondary)
                                    .frame(width: 16)
                                Text(branch)
                                    .font(.system(size: 12))
                                    .foregroundStyle(branch == gitProvider.currentBranch ? .primary : .secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.branchItem(branch))
                    }
                }
            }
            .frame(maxHeight: 300)

            if !errorMessage.isEmpty {
                Divider()
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(8)
                    .transition(PineAnimation.fadeTransition)
            }
        }
        .frame(width: 280)
        .animation(PineAnimation.quick, value: errorMessage.isEmpty)
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
