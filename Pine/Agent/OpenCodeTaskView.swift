import SwiftUI

@MainActor
struct OpenCodeTaskView: View {
    let registry: ProjectRegistry
    let project: AgentTaskProjectIdentity
    let onDismiss: () -> Void

    @State private var submission: OpenCodeTaskSubmission

    init(
        registry: ProjectRegistry,
        project: AgentTaskProjectIdentity,
        onDismiss: @escaping () -> Void
    ) {
        self.registry = registry
        self.project = project
        self.onDismiss = onDismiss
        _submission = State(initialValue: OpenCodeTaskSubmission(
            registry: registry, project: project
        ))
    }

    private var runtime: OpenCodeACPTaskRuntime? { submission.runtime }
    private var taskID: UUID? { submission.taskID }
    private var isSending: Bool { submission.isSending }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(Strings.openCodeTaskTitle, systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button(Strings.openCodeTaskClose, action: onDismiss)
            }

            // Contextual "How to run": the task's own execution observations,
            // not a permanent settings surface (#1760). Hidden until the
            // session produces its discovery report.
            if let report = runtime?.discoveryReport {
                howToRun(report: report)
            }

            if let runtime, let snapshot = runtime.snapshot {
                status(snapshot.state)
                if snapshot.inputFenced {
                    Text(Strings.openCodeTaskInputFenced)
                        .foregroundStyle(.orange)
                }
                if !snapshot.children.isEmpty {
                    Text(Strings.openCodeTaskChildrenUnverified)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !snapshot.result.isEmpty {
                    ScrollView {
                        Text(verbatim: snapshot.result)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 100, maxHeight: 260)
                    .accessibilityIdentifier(AccessibilityID.openCodeTaskResult)
                }
                if snapshot.state == .unverified {
                    Label(Strings.openCodeTaskUnverified, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.questions, id: \.id) { question in
                    OpenCodeTaskQuestionView(
                        question: question, runtime: runtime, isBusy: isSending,
                        perform: submission.perform
                    )
                }
            } else {
                ContentUnavailableView(
                    Strings.openCodeTaskEmpty,
                    systemImage: "arrow.up.message",
                    description: Text(Strings.openCodeTaskEmptyDetail)
                )
            }

            if submission.failure == .instructionTooLong || submission.isTooLong {
                submissionFailure(
                    Strings.workspaceRequestTooLong, detail: Strings.workspaceRequestTooLongDetail
                )
            } else if submission.failure == .actionFailed
                        || runtime?.lastDispatch == .uncertain {
                submissionFailure(Strings.openCodeTaskActionFailed, detail: nil)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(taskID == nil ? Strings.openCodeTaskRequest : Strings.openCodeTaskFeedback)
                    .font(.caption.weight(.medium))
                TextEditor(text: $submission.input)
                    .frame(minHeight: 72, maxHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                    // A pending retry sends the task's recorded goal, not field text.
                    .disabled(submission.isAwaitingRetry)
                    .accessibilityIdentifier(AccessibilityID.openCodeTaskInput)
                HStack {
                    if runtime?.isActive == true {
                        Button(Strings.openCodeTaskCancel) {
                            submission.perform { try await runtime?.cancel() }
                        }
                        .disabled(isSending || runtime?.snapshot?.context == nil)
                        .accessibilityIdentifier(AccessibilityID.openCodeTaskCancel)
                    }
                    Spacer()
                    Button(taskID == nil ? Strings.openCodeTaskSend : Strings.openCodeTaskSendFeedback) {
                        submission.send()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending
                               || submission.trimmedInput.isEmpty
                               || submission.isTooLong
                               || runtime?.snapshot?.inputFenced == true)
                    .accessibilityIdentifier(AccessibilityID.openCodeTaskSend)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .disabled(isSending && taskID == nil)
    }

    private func submissionFailure(
        _ message: LocalizedStringKey, detail: LocalizedStringKey?
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message)
            if let detail {
                Text(detail)
            }
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.openCodeTaskError)
    }

    /// The contextual "How to run" disclosure (#1765): agent,
    /// connection/account, and the native execution settings with their
    /// provenance, exactly as the session's discovery report observed them.
    private func howToRun(report: AgentTaskDiscoveryReport) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(AgentTaskHowToRun.lines(report: report)) { line in
                    howToRunLine(line)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(Strings.howToRunTitle, systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .accessibilityIdentifier(AccessibilityID.howToRunDisclosure)
    }

    private func howToRunLine(_ line: AgentTaskHowToRunLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(howToRunTitle(for: line.kind))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            howToRunValue(line)
        }
        // One VoiceOver stop per row: label and value read together.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(howToRunAccessibilityID(for: line.kind))
    }

    private func howToRunTitle(for kind: AgentTaskHowToRunLine.Kind) -> LocalizedStringKey {
        switch kind {
        case .agent: Strings.howToRunAgent
        case .account: Strings.howToRunAccount
        case .model: Strings.howToRunModel
        case .reasoningEffort: Strings.howToRunEffort
        case .permissions: Strings.howToRunPermissions
        }
    }

    private func howToRunAccessibilityID(for kind: AgentTaskHowToRunLine.Kind) -> String {
        switch kind {
        case .agent: AccessibilityID.howToRunAgentLine
        case .account: AccessibilityID.howToRunAccountLine
        case .model: AccessibilityID.howToRunModelLine
        case .reasoningEffort: AccessibilityID.howToRunEffortLine
        case .permissions: AccessibilityID.howToRunPermissionsLine
        }
    }

    @ViewBuilder
    private func howToRunValue(_ line: AgentTaskHowToRunLine) -> some View {
        switch line.kind {
        case .agent:
            HStack(spacing: 6) {
                Text(agentDisplayName)
                if let version = line.agentVersion {
                    Text(verbatim: version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .account:
            switch line.account {
            case .authenticated(let label):
                if let label {
                    Text(verbatim: label)
                } else {
                    Text(Strings.howToRunNativeCredentials)
                }
            case .loginRequired:
                Text(Strings.howToRunLoginRequired)
            case .accountUnavailable:
                Text(Strings.howToRunAccountUnavailable)
            case .expiredCredentials:
                Text(Strings.howToRunExpiredCredentials)
            case .unknown, nil:
                Text(Strings.howToRunUnknown)
            }
        case .model, .reasoningEffort, .permissions:
            switch line.setting {
            case .confirmed(let value):
                Text(verbatim: value).textSelection(.enabled)
            case .agentSettings:
                Text(Strings.howToRunAgentSettings)
            case .cliControls:
                Text(Strings.howToRunCliControls)
            case nil:
                EmptyView()
            }
        }
    }

    private var agentDisplayName: String {
        (try? AgentPresentationCatalog.builtIn(stableIdentifier: "openCode"))?.displayName
            ?? "OpenCode"
    }

    private func status(_ state: OpenCodeACPSession.State) -> some View {
        Label(
            Self.sessionStateText(state),
            systemImage: state == .working || state == .submitted
                ? "ellipsis.circle" : "info.circle"
        )
        .accessibilityIdentifier(AccessibilityID.openCodeTaskStatus)
    }

    /// The wording for one session state, shared with the Pine 3 task detail.
    static func sessionStateText(_ state: OpenCodeACPSession.State) -> LocalizedStringKey {
        switch state {
        case .fresh, .starting, .idle: Strings.openCodeTaskStarting
        case .submitted, .working: Strings.openCodeTaskWorking
        case .waiting: Strings.openCodeTaskWaiting
        case .unverified: Strings.openCodeTaskResultReady
        case .cancelRequested: Strings.openCodeTaskCancelling
        case .cancelled: Strings.openCodeTaskCancelled
        case .failed, .blocked: Strings.openCodeTaskFailed
        case .unknown: Strings.openCodeTaskUnknown
        case .stopped: Strings.openCodeTaskStopped
        }
    }
}
