//
//  CommitDetailPopover.swift
//  Pine
//

import SwiftUI

/// Popover showing detailed commit information from a blame line click.
struct CommitDetailView: View {
    let blame: GitBlameLine
    let repoURL: URL?

    @State private var commitStats: String?

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Hash
            HStack {
                Text("Commit")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(blame.hash)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Divider()

            // Author
            HStack {
                Image(systemName: "person")
                    .foregroundStyle(.secondary)
                Text(blame.author)
            }

            // Date
            HStack {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text(Self.dateFormatter.string(from: blame.authorTime))
            }

            Divider()

            // Summary
            Text(blame.summary)
                .font(.body)
                .fontWeight(.medium)

            // Commit stats (files changed)
            if let stats = commitStats {
                Divider()
                Text(stats)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(minWidth: 300, maxWidth: 450, alignment: .leading)
        .task {
            await loadCommitStats()
        }
    }

    private func loadCommitStats() async {
        guard let repoURL else { return }
        let hash = blame.hash
        let stats = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = GitStatusProvider.runGit(
                    ["show", "--stat", "--format=", hash], at: repoURL
                )
                if result.exitCode == 0 {
                    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        await MainActor.run {
            commitStats = stats
        }
    }
}
