//
//  RecoveryDialogView.swift
//  Pine
//

import SwiftUI

/// Shows a dialog listing recovered unsaved files after a crash.
struct RecoveryDialogView: View {
    let entries: [(UUID, RecoveryEntry)]
    let onRecover: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)

            Text(Strings.recoveryTitle)
                .font(.headline)

            Text(Strings.recoveryMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            List {
                ForEach(entries, id: \.0) { _, entry in
                    HStack {
                        Image(systemName: "doc.text")
                        VStack(alignment: .leading) {
                            Text(fileName(from: entry.originalPath))
                                .font(.body)
                            Text(entry.timestamp, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 200)

            HStack(spacing: 12) {
                Button(role: .destructive) {
                    onDiscard()
                } label: {
                    Text(Strings.recoveryDiscard)
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onRecover()
                } label: {
                    Text(Strings.recoveryRecoverAll)
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func fileName(from path: String) -> String {
        if path.isEmpty { return Strings.recoveryUntitled }
        return (path as NSString).lastPathComponent
    }
}
