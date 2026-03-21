//
//  RecoveryDialogView.swift
//  Pine
//
//  Created by Claude on 21.03.2026.
//

import SwiftUI

/// Sheet presented after launch when crash-recovery data is available.
///
/// Shown when Pine detects unsaved content from a previous session that ended
/// unexpectedly (crash, force quit, or power loss). Lists the affected files
/// and offers "Recover All" or "Discard" actions.
struct RecoveryDialogView: View {
    let recoveries: [RecoveryFileData]
    let onRecover: ([RecoveryFileData]) -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.recoveryTitle)
                        .font(.headline)
                    Text(Strings.recoveryMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // File list
            VStack(alignment: .leading, spacing: 2) {
                ForEach(recoveries, id: \.tabID) { recovery in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .frame(width: 16)

                        Text(recovery.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text(recovery.timestamp, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Buttons
            HStack {
                Spacer()

                Button(Strings.recoveryDiscard) {
                    onDiscard()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AccessibilityID.recoveryDiscardButton)

                Button(Strings.recoveryRecoverAll) {
                    onRecover(recoveries)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.recoveryRecoverButton)
            }
        }
        .padding(20)
        .frame(width: 420)
        .accessibilityIdentifier(AccessibilityID.recoveryDialog)
    }
}
