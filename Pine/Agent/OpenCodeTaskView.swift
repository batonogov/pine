import SwiftUI

@MainActor
struct OpenCodeTaskView: View {
    let registry: ProjectRegistry
    let project: AgentTaskProjectIdentity
    let onDismiss: () -> Void

    @State private var taskID: UUID?
    @State private var input = ""
    @State private var answers: [UUID: [String: String]] = [:]
    @State private var isSending = false
    @State private var actionFailed = false

    private var runtime: OpenCodeACPTaskRuntime? {
        taskID.flatMap { registry.openCodeRuntime(for: $0) }
    }

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
                    questionView(question, runtime: runtime)
                }
            } else {
                ContentUnavailableView(
                    Strings.openCodeTaskEmpty,
                    systemImage: "arrow.up.message",
                    description: Text(Strings.openCodeTaskEmptyDetail)
                )
            }

            if actionFailed || runtime?.lastDispatch == .uncertain {
                Text(Strings.openCodeTaskActionFailed)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AccessibilityID.openCodeTaskError)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(taskID == nil ? Strings.openCodeTaskRequest : Strings.openCodeTaskFeedback)
                    .font(.caption.weight(.medium))
                TextEditor(text: $input)
                    .frame(minHeight: 72, maxHeight: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    }
                    .accessibilityIdentifier(AccessibilityID.openCodeTaskInput)
                HStack {
                    if runtime?.isActive == true {
                        Button(Strings.openCodeTaskCancel) {
                            perform { try await runtime?.cancel() }
                        }
                        .disabled(isSending || runtime?.snapshot?.context == nil)
                        .accessibilityIdentifier(AccessibilityID.openCodeTaskCancel)
                    }
                    Spacer()
                    Button(taskID == nil ? Strings.openCodeTaskSend : Strings.openCodeTaskSendFeedback) {
                        send()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSending || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || runtime?.snapshot?.inputFenced == true)
                    .accessibilityIdentifier(AccessibilityID.openCodeTaskSend)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 640)
        .disabled(isSending && taskID == nil)
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
        let text = switch state {
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
        return Label(text, systemImage: state == .working || state == .submitted
                     ? "ellipsis.circle" : "info.circle")
            .accessibilityIdentifier(AccessibilityID.openCodeTaskStatus)
    }

    @ViewBuilder
    private func questionView(
        _ question: OpenCodeACPSession.Question,
        runtime: OpenCodeACPTaskRuntime
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if question.permission {
                if let title = permissionTitle(question) {
                    Text(verbatim: title)
                } else {
                    Text(Strings.openCodeTaskPermission)
                }
                HStack {
                    Button(Strings.openCodeTaskAllowOnce) {
                        guard let optionID = question.allowOnceOptionID else { return }
                        perform {
                            try await runtime.answerPermission(
                                question, optionID: optionID, decision: .allowOnce
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(Strings.openCodeTaskDeny) {
                        guard let optionID = question.denyOptionID else { return }
                        perform {
                            try await runtime.answerPermission(
                                question, optionID: optionID, decision: .deny
                            )
                        }
                    }
                }
            } else if let form = question.form {
                Text(verbatim: form.message)
                ForEach(form.fields.keys.sorted(), id: \.self) { key in
                    if let field = form.fields[key] {
                        fieldView(field, question: question, key: key)
                    }
                }
                Button(Strings.openCodeTaskAnswer) {
                    perform {
                        try await runtime.answerQuestion(
                            question, answers: (answers[question.id] ?? [:]).mapValues { [$0] }
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || !requiredAnswersArePresent(form, question: question))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier(AccessibilityID.openCodeTaskQuestion)
    }

    @ViewBuilder
    private func fieldView(
        _ field: OpenCodeACPForm.Field,
        question: OpenCodeACPSession.Question,
        key: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: field.title ?? key)
            if let choices = field.choices {
                Picker(field.title ?? key, selection: answerBinding(question: question, key: key)) {
                    ForEach(choices, id: \.self) { choice in
                        Text(verbatim: field.choiceTitles[choice] ?? choice).tag(choice)
                    }
                }
                .labelsHidden()
                .onAppear {
                    if answers[question.id]?[key] == nil {
                        answers[question.id, default: [:]][key] = choices.first
                    }
                }
            } else {
                TextField(field.title ?? key, text: answerBinding(question: question, key: key))
                    .textFieldStyle(.roundedBorder)
            }
            if let detail = field.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func answerBinding(
        question: OpenCodeACPSession.Question, key: String
    ) -> Binding<String> {
        Binding(
            get: { answers[question.id]?[key] ?? "" },
            set: { answers[question.id, default: [:]][key] = $0 }
        )
    }

    private func requiredAnswersArePresent(
        _ form: OpenCodeACPForm, question: OpenCodeACPSession.Question
    ) -> Bool {
        form.fields.allSatisfy { key, field in
            !field.required || !(answers[question.id]?[key]?.isEmpty ?? true)
        }
    }

    private func permissionTitle(_ question: OpenCodeACPSession.Question) -> String? {
        guard case .object(let fields) = question.details,
              case .string(let title) = fields["title"] else { return nil }
        return title
    }

    private func send() {
        let text = input
        if let runtime {
            perform {
                _ = try await runtime.submit(text)
                input = ""
            }
        } else {
            isSending = true
            actionFailed = false
            Task { @MainActor in
                defer { isSending = false }
                do {
                    taskID = try await registry.startOpenCodeTask(
                        instruction: text, project: project,
                        onTaskCreated: { taskID = $0 }
                    )
                    input = ""
                } catch {
                    actionFailed = true
                }
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        isSending = true
        actionFailed = false
        Task { @MainActor in
            defer { isSending = false }
            do { try await operation() } catch { actionFailed = true }
        }
    }
}
