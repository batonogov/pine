//
//  UserTaskRunPresenter.swift
//  Pine
//
//  Project-scoped task output and lifecycle controls.
//

import AppKit
import SwiftUI

@MainActor
enum UserTaskOutputClipboard {
    static func copy(_ output: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }
}

struct UserTaskRunPresenter: ViewModifier {
    let store: UserTaskRunStore

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.isOutputVisible {
                    UserTaskRunHistoryView(store: store)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !store.isOutputVisible, !store.runs.isEmpty {
                    Button {
                        store.isOutputVisible = true
                    } label: {
                        Label(
                            Strings.userTaskOpenOutput,
                            systemImage: "terminal"
                        )
                    }
                    .padding(10)
                    .accessibilityIdentifier(
                        AccessibilityID.userTaskShowOutputButton
                    )
                }
            }
    }
}

private struct UserTaskRunHistoryView: View {
    let store: UserTaskRunStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.runs.isEmpty {
                Text(Strings.userTaskOutputEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.runs) { run in
                            UserTaskRunRow(
                                run: run,
                                cancel: {
                                    store.cancelRun(id: run.id)
                                }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: 280)
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(
                Strings.userTaskOutputTitle,
                systemImage: "terminal"
            )
            .font(.headline)
            // Put the panel marker on a semantic leaf. Applying an
            // accessibility identifier to the root VStack causes SwiftUI on
            // macOS to propagate it over descendant controls, hiding their
            // more specific identifiers from VoiceOver and XCUITest.
            .accessibilityIdentifier(AccessibilityID.userTaskOutputPanel)
            Spacer()
            Button(Strings.userTaskClearFinished) {
                store.clearFinished()
            }
            .disabled(!store.runs.contains { !$0.state.isActive })
            .accessibilityIdentifier(
                AccessibilityID.userTaskClearFinishedButton
            )
            Button {
                store.isOutputVisible = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(Strings.userTaskCloseOutput)
            .accessibilityLabel(Strings.userTaskCloseOutput)
            .accessibilityIdentifier(
                AccessibilityID.userTaskCloseOutputButton
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

private struct UserTaskRunRow: View {
    let run: UserTaskRun
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(run.taskLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    // As with the panel marker, keep the stable run id on a
                    // leaf so status, elapsed, copy, and cancel controls retain
                    // their own accessibility identities.
                    .accessibilityIdentifier(
                        AccessibilityID.userTaskRun(run.id)
                    )
                Text(run.statusSummary)
                    .foregroundStyle(statusColor)
                    .accessibilityIdentifier(
                        AccessibilityID.userTaskStatusLabel(run.id)
                    )
                UserTaskElapsedView(run: run)
                Spacer()
                if run.hasOutput {
                    Button {
                        UserTaskOutputClipboard.copy(
                            run.outputCopyPayload
                        )
                    } label: {
                        Label(
                            Strings.userTaskCopyOutput,
                            systemImage: "doc.on.doc"
                        )
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier(
                        AccessibilityID.userTaskCopyOutputButton(run.id)
                    )
                }
                if run.state.isActive {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(run.statusSummary)
                        .accessibilityIdentifier(
                            AccessibilityID.userTaskProgressIndicator(run.id)
                        )
                    Button(Strings.userTaskCancel) {
                        cancel()
                    }
                    .disabled(run.state == .cancelling)
                    .accessibilityIdentifier(
                        AccessibilityID.userTaskCancelButton(run.id)
                    )
                }
            }

            Text(verbatim: run.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if run.hasOutput {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: run.displayOutputPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(
                            AccessibilityID.userTaskOutputText(run.id)
                        )
                    if run.displayOutputPreviewWasTruncated {
                        Text(Strings.userTaskOutputPreviewTruncated)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                AccessibilityID
                                    .userTaskOutputTruncationNotice(run.id)
                            )
                    }
                }
                .padding(6)
                .background(
                    .quaternary,
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        switch run.state {
        case .pending, .running, .cancelling:
            return .secondary
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }
}

private struct UserTaskElapsedView: View {
    let run: UserTaskRun

    var body: some View {
        if run.state.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                elapsedLabel(at: context.date)
            }
        } else {
            elapsedLabel(at: run.finishedAt ?? run.startedAt)
        }
    }

    private func elapsedLabel(at date: Date) -> some View {
        Text(Strings.userTaskElapsed(run.elapsedText(at: date)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(
                AccessibilityID.userTaskElapsedLabel(run.id)
            )
    }
}
