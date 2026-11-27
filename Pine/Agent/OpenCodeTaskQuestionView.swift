//
//  OpenCodeTaskQuestionView.swift
//  Pine
//
//  One pending OpenCode question or permission with its answer controls.
//

import SwiftUI

/// A pending question or permission, answerable in place. Shared by the
/// `OpenCodeTaskView` sheet and the Pine 3 task detail.
struct OpenCodeTaskQuestionView: View {
    let question: OpenCodeACPSession.Question
    let runtime: OpenCodeACPTaskRuntime
    /// `true` while another control of the same session is in flight.
    let isBusy: Bool
    /// Runs one session control and records how it ended. The operation is
    /// escaping because it runs inside the returned task.
    let perform: (@escaping @MainActor () async throws -> Void) -> Task<Void, Never>

    @State private var answers: [UUID: [String: String]] = [:]

    var body: some View {
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
                        fieldView(field, key: key)
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
                .disabled(isBusy || !requiredAnswersArePresent(form))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier(AccessibilityID.openCodeTaskQuestion)
    }

    @ViewBuilder
    private func fieldView(_ field: OpenCodeACPForm.Field, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: field.title ?? key)
            if let choices = field.choices {
                Picker(field.title ?? key, selection: answerBinding(key: key)) {
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
                TextField(field.title ?? key, text: answerBinding(key: key))
                    .textFieldStyle(.roundedBorder)
            }
            if let detail = field.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func answerBinding(key: String) -> Binding<String> {
        Binding(
            get: { answers[question.id]?[key] ?? "" },
            set: { answers[question.id, default: [:]][key] = $0 }
        )
    }

    private func requiredAnswersArePresent(_ form: OpenCodeACPForm) -> Bool {
        form.fields.allSatisfy { key, field in
            !field.required || !(answers[question.id]?[key]?.isEmpty ?? true)
        }
    }

    private func permissionTitle(_ question: OpenCodeACPSession.Question) -> String? {
        guard case .object(let fields) = question.details,
              case .string(let title) = fields["title"] else { return nil }
        return title
    }
}
