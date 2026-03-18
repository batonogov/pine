//
//  BranchSwitcherView.swift
//  Pine
//

import SwiftUI

struct BranchSwitcherView: View {
    var gitProvider: GitStatusProvider
    @Binding var isPresented: Bool
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
            }
        }
        .frame(width: 280)
    }

    private func switchToBranch(_ branch: String) {
        guard branch != gitProvider.currentBranch else {
            isPresented = false
            return
        }

        if gitProvider.hasUncommittedChanges {
            let alert = NSAlert()
            alert.messageText = Strings.branchUncommittedChangesTitle
            alert.informativeText = Strings.branchUncommittedChangesMessage(branch)
            alert.addButton(withTitle: Strings.branchUncommittedChangesSwitch)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let result = gitProvider.checkoutBranch(branch)
        if result.success {
            errorMessage = ""
            isPresented = false
        } else {
            errorMessage = result.error
        }
    }
}
