//
//  DiffDetailView.swift
//  Pine
//
//  Full diff view for the editor area showing hunks of a selected file.
//

import SwiftUI

// MARK: - Detail View (editor area)

struct DiffDetailView: View {
    let entry: DiffFileEntry
    let gitProvider: GitStatusProvider
    let diffPanel: DiffPanelProvider

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                fileHeader
                if entry.hunks.isEmpty {
                    noHunksPlaceholder
                } else {
                    ForEach(Array(entry.hunks.enumerated()), id: \.element.id) { index, hunk in
                        DiffHunkDetailView(
                            hunk: hunk,
                            hunkIndex: index,
                            filePath: entry.relativePath,
                            isStaged: entry.isStaged,
                            gitProvider: gitProvider,
                            diffPanel: diffPanel
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.diffDetailView)
    }

    private var fileHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIconMapper.iconForFile(
                (entry.relativePath as NSString).lastPathComponent
            ))
            .font(.system(size: 14))
            .foregroundStyle(.secondary)

            Text(entry.relativePath)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(statusLetter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(entry.status.color)

            Spacer()

            fileActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusLetter: String {
        switch entry.status {
        case .modified: "M"
        case .added:    "A"
        case .deleted:  "D"
        case .untracked: "U"
        case .staged:   "S"
        case .conflict: "C"
        case .mixed:    "M"
        }
    }

    @ViewBuilder
    private var fileActions: some View {
        if entry.isStaged {
            Button {
                Task { await diffPanel.unstageFile(entry.relativePath, gitProvider: gitProvider) }
            } label: {
                Label(Strings.diffPanelUnstageFile, systemImage: "minus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await diffPanel.stageFile(entry.relativePath, gitProvider: gitProvider) }
            } label: {
                Label(Strings.diffPanelStageFile, systemImage: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private var noHunksPlaceholder: some View {
        VStack {
            Spacer().frame(height: 40)
            Text(entry.status == .untracked
                 ? Strings.diffDetailUntrackedFile
                 : Strings.diffDetailNoHunks)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Placeholder (no file selected)

struct DiffPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label(Strings.diffDetailSelectFile, systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(Strings.diffDetailSelectFileDescription)
        }
        .accessibilityIdentifier(AccessibilityID.diffDetailPlaceholder)
    }
}

// MARK: - Hunk Detail View

struct DiffHunkDetailView: View {
    let hunk: DiffHunk
    let hunkIndex: Int
    let filePath: String
    let isStaged: Bool
    let gitProvider: GitStatusProvider
    let diffPanel: DiffPanelProvider

    @State private var showDiscardConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hunkHeader
            hunkLines
        }
        .accessibilityIdentifier(AccessibilityID.diffPanelHunk(hunkIndex))
        .alert(Strings.diffPanelDiscardConfirmTitle, isPresented: $showDiscardConfirm) {
            Button(Strings.diffPanelDiscardButton, role: .destructive) {
                Task { await diffPanel.discardHunk(hunk, filePath: filePath, gitProvider: gitProvider) }
            }
            Button(Strings.diffPanelCancelButton, role: .cancel) { }
        } message: {
            Text(Strings.diffPanelDiscardConfirmMessage)
        }
    }

    private var hunkHeader: some View {
        HStack(spacing: 6) {
            Text(hunkSummary)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if isStaged {
                Button {
                    Task { await diffPanel.unstageHunk(hunk, filePath: filePath, gitProvider: gitProvider) }
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(Strings.diffPanelUnstageHunk)
                .accessibilityIdentifier(AccessibilityID.diffPanelUnstageHunkButton)
            } else {
                Button {
                    Task { await diffPanel.stageHunk(hunk, filePath: filePath, gitProvider: gitProvider) }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(Strings.diffPanelStageHunk)
                .accessibilityIdentifier(AccessibilityID.diffPanelStageHunkButton)

                Button { showDiscardConfirm = true } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(Strings.diffPanelDiscardHunk)
                .accessibilityIdentifier(AccessibilityID.diffPanelDiscardHunkButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    private var hunkSummary: String {
        let header = hunk.header
        guard let endRange = header.range(
            of: "@@", options: .backwards,
            range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex
        ) else { return header }
        return String(header[...endRange.upperBound]).trimmingCharacters(in: .whitespaces)
    }

    private var hunkLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines) { line in
                HStack(spacing: 0) {
                    Text(linePrefix(line.kind))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .center)
                    Text(line.content)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .background(lineBackground(line.kind))
            }
        }
    }

    private func linePrefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: " "
        case .added:   "+"
        case .removed: "-"
        }
    }

    private func lineBackground(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .added:   Color.green.opacity(0.12)
        case .removed: Color.red.opacity(0.12)
        }
    }
}
