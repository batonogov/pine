//
//  LSPSettingsView.swift
//  Pine
//

import AppKit
import SwiftUI

/// Native macOS Settings pane for global and per-language LSP configuration.
///
/// Per-language overrides apply immediately: edits are debounced, validated,
/// and persisted the instant they describe a valid launch configuration.
/// Invalid partial text is retained as a per-language in-memory draft with an
/// inline error so switching languages or closing Settings never silently
/// discards in-progress work. There is no Apply button — Reset remains the
/// explicit return to the built-in configuration. Issue #1242.
struct LSPSettingsView: View {
    let settings: LSPSettings
    private let resolver: any LanguageServerResolving
    private let locale: Locale

    @State private var selectedLanguage: String
    @State private var drafts: [String: LSPSettingsDraft] = [:]
    @State private var debounceTask: Task<Void, Never>?
    @State private var executablePicker: ExecutablePicker?

    init(
        settings: LSPSettings,
        resolver: any LanguageServerResolving =
            LanguageServerResolver.defaultResolver,
        locale: Locale = .current
    ) {
        self.settings = settings
        self.resolver = resolver
        self.locale = locale

        let config = LanguageServerRegistry.allServers.first
        _selectedLanguage = State(
            initialValue: config?.language ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Strings.lspSettingsTitle)
                .font(.title2.weight(.semibold))

            Toggle(
                isOn: Binding(
                    get: { settings.isEnabled },
                    set: { settings.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Strings.lspEnabled)
                    Text(Strings.lspEnabledHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 20) {
                languageList
                Divider()
                languageEditor
            }
        }
        .padding(20)
        .frame(width: 720, height: 500)
        .environment(\.locale, locale)
        .onAppear {
            loadDraft(for: selectedLanguage)
        }
        .onChange(of: selectedLanguage) { _, language in
            loadDraft(for: language)
        }
        .onChange(of: settings.isEnabled) { _, _ in
            // Re-evaluate the active draft when the global toggle flips so
            // a freshly enabled editor reflects the persisted state.
            loadDraft(for: selectedLanguage)
        }
    }

    private var languageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Strings.lspLanguages)
                .font(.headline)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(
                        LanguageServerRegistry.allServers,
                        id: \.language
                    ) { config in
                        Button {
                            selectedLanguage = config.language
                        } label: {
                            languageRow(config)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(
                                    selectedLanguage == config.language
                                        ? Color.accentColor.opacity(0.16)
                                        : Color.clear
                                )
                        }
                    }
                }
            }
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(width: 225)
    }

    @ViewBuilder
    private var languageEditor: some View {
        if let config = selectedConfig {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(languageName(config.language))
                        .font(.headline)
                    Spacer()
                    statusBadge(for: config)
                }

                if case .resolved(let launch) = resolution(for: config) {
                    Text(launch.executablePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    TextField(
                        "settings.lsp.executable",
                        text: executablePathBinding,
                        prompt: Text(Strings.lspExecutablePlaceholder)
                    )
                    .accessibilityIdentifier("lsp-settings-executable")
                    Button(Strings.lspChooseExecutable) {
                        chooseExecutable(for: config.language)
                    }
                    .accessibilityIdentifier("lsp-settings-choose-executable")
                }

                Toggle(
                    Strings.lspCustomArguments,
                    isOn: usesCustomArgumentsBinding
                )
                .accessibilityIdentifier("lsp-settings-custom-arguments")

                Text(Strings.lspArgumentsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: argumentsTextBinding)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator)
                    }
                    .frame(minHeight: 105)
                    .disabled(!draftUsesCustomArguments)
                    .opacity(draftUsesCustomArguments ? 1 : 0.55)
                    .accessibilityIdentifier("lsp-settings-arguments")

                Label(
                    Strings.lspDirectLaunchHelp,
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let validationError = draft(for: selectedLanguage)?.error {
                    Label(
                        validationMessage(validationError),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("lsp-settings-error")
                }

                Spacer(minLength: 0)

                HStack {
                    Button(Strings.lspReset) {
                        settings.resetServerOverride(
                            language: config.language
                        )
                        removeDraft(for: config.language)
                        loadDraft(for: config.language)
                    }
                    .disabled(
                        !canReset(language: config.language)
                    )
                    .accessibilityIdentifier("lsp-settings-reset")

                    Spacer()
                }
            }
            .disabled(!settings.isEnabled)
            .opacity(settings.isEnabled ? 1 : 0.6)
        }
    }

    private func languageRow(
        _ config: LanguageServerConfig
    ) -> some View {
        let resolution = resolution(for: config)
        return HStack(spacing: 9) {
            Image(
                systemName: resolution.launchConfiguration == nil
                    ? "exclamationmark.circle.fill"
                    : "checkmark.circle.fill"
            )
            .foregroundStyle(
                resolution.launchConfiguration == nil ? .orange : .green
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(languageName(config.language))
                    .foregroundStyle(.primary)
                Text(statusSummary(resolution))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func statusBadge(
        for config: LanguageServerConfig
    ) -> some View {
        let resolution = resolution(for: config)
        return Text(statusSummary(resolution))
            .font(.caption.weight(.medium))
            .foregroundStyle(
                resolution.launchConfiguration == nil ? .orange : .green
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    // MARK: - Draft management

    private var selectedConfig: LanguageServerConfig? {
        LanguageServerRegistry.server(forLanguage: selectedLanguage)
    }

    private func draft(for language: String) -> LSPSettingsDraft? {
        drafts[language]
    }

    private func removeDraft(for language: String) {
        drafts[language] = nil
    }

    /// `true` when Reset would have an effect: either a persisted override
    /// exists, or the in-memory draft holds unsaved/invalid edits that differ
    /// from the built-in default.
    private func canReset(language: String) -> Bool {
        if settings.serverOverride(for: language) != nil {
            return true
        }
        guard let draft = drafts[language] else {
            return false
        }
        // A draft with an error means the user typed something invalid.
        if draft.error != nil { return true }
        // A non-empty executable path that hasn't been persisted yet.
        if !draft.executablePath.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            return true
        }
        return false
    }

    /// Loads the draft for `language` from the persisted override, or from the
    /// built-in registry default when no override exists. Existing in-memory
    /// drafts (including invalid partials) are preserved so switching languages
    /// never loses in-progress edits.
    private func loadDraft(for language: String) {
        guard let config = LanguageServerRegistry.server(
            forLanguage: language
        ) else {
            return
        }
        // Preserve an existing draft — it may hold unsaved invalid edits.
        guard drafts[language] == nil else { return }

        let serverOverride = settings.serverOverride(for: language)
        let executablePath = serverOverride?.executablePath ?? ""
        let usesCustomArguments = serverOverride?.arguments != nil
        let argumentsText = (
            serverOverride?.arguments ?? config.arguments
        ).joined(separator: "\n")
        drafts[language] = LSPSettingsDraft(
            executablePath: executablePath,
            usesCustomArguments: usesCustomArguments,
            argumentsText: argumentsText,
            error: nil
        )
    }

    // MARK: - Bindings (write to draft, schedule debounced persist)

    private var executablePathBinding: Binding<String> {
        Binding(
            get: { draft(for: selectedLanguage)?.executablePath ?? "" },
            set: { newValue in
                updateDraft(for: selectedLanguage) { draft in
                    draft.executablePath = newValue
                    draft.error = nil
                }
                schedulePersist(for: selectedLanguage)
            }
        )
    }

    private var argumentsTextBinding: Binding<String> {
        Binding(
            get: { draft(for: selectedLanguage)?.argumentsText ?? "" },
            set: { newValue in
                updateDraft(for: selectedLanguage) { draft in
                    draft.argumentsText = newValue
                    draft.error = nil
                }
                schedulePersist(for: selectedLanguage)
            }
        )
    }

    private var usesCustomArgumentsBinding: Binding<Bool> {
        Binding(
            get: { draftUsesCustomArguments },
            set: { newValue in
                updateDraft(for: selectedLanguage) { draft in
                    draft.usesCustomArguments = newValue
                    draft.error = nil
                }
                schedulePersist(for: selectedLanguage)
            }
        )
    }

    private var draftUsesCustomArguments: Bool {
        draft(for: selectedLanguage)?.usesCustomArguments ?? false
    }

    private func updateDraft(
        for language: String,
        _ mutate: (inout LSPSettingsDraft) -> Void
    ) {
        loadDraft(for: language)
        guard var existing = drafts[language] else { return }
        mutate(&existing)
        drafts[language] = existing
    }

    // MARK: - Debounced validation + immediate persist

    /// Schedules a trailing-edge validation pass. Valid edits are persisted
    /// atomically; invalid partial text stays in the in-memory draft with an
    /// inline error and is never written to disk.
    private func schedulePersist(for language: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(
                for: .seconds(UITimings.Debounce.lspSettings)
            )
            guard !Task.isCancelled else { return }
            validateAndPersist(for: language)
        }
    }

    private func validateAndPersist(for language: String) {
        guard let config = LanguageServerRegistry.server(
            forLanguage: language
        ), let draft = drafts[language] else {
            return
        }

        let arguments: [String]? = draft.usesCustomArguments
            ? parsedArguments(from: draft.argumentsText)
            : nil

        do {
            try settings.setServerOverride(
                language: config.language,
                executablePath: draft.executablePath,
                arguments: arguments
            )
            // Persist succeeded — clear the inline error and refresh the
            // draft so it mirrors the now-canonical persisted state.
            updateDraft(for: language) { current in
                current.error = nil
            }
        } catch let error as LSPSettingsValidationError {
            // Keep the invalid text as a draft with an inline error.
            // Never persist; never discard.
            updateDraft(for: language) { current in
                current.error = error
            }
        } catch {
            updateDraft(for: language) { current in
                current.error = .invalidPathCharacters
            }
        }
    }

    /// Each line is one literal process argument. No quote expansion,
    /// interpolation, or shell tokenization is performed.
    private func parsedArguments(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    // MARK: - Executable picker (NSOpenPanel)

    private func chooseExecutable(for language: String) {
        let picker = ExecutablePicker { [weak settings] url in
            guard let settings else { return }
            updateDraft(for: language) { draft in
                draft.executablePath = url.path
                draft.error = nil
            }
            // Persist immediately — the path came from the filesystem picker
            // so it is already valid; no need to wait for the debounce.
            // Re-read the draft snapshot after the update so the arguments
            // reflect the latest in-memory state.
            let currentDraft = draft(for: language)
            let arguments: [String]? = currentDraft?.usesCustomArguments
                == true
                ? parsedArguments(
                    from: currentDraft?.argumentsText ?? ""
                )
                : nil
            do {
                try settings.setServerOverride(
                    language: language,
                    executablePath: url.path,
                    arguments: arguments
                )
                updateDraft(for: language) { current in
                    current.error = nil
                }
            } catch let error as LSPSettingsValidationError {
                updateDraft(for: language) { current in
                    current.error = error
                }
            } catch {
                updateDraft(for: language) { current in
                    current.error = .invalidPathCharacters
                }
            }
        }
        self.executablePicker = picker
        picker.present(context: DialogPresenter.forKeyWindow())
    }

    // MARK: - Resolution + display helpers

    private func resolution(
        for config: LanguageServerConfig
    ) -> LanguageServerResolution {
        resolver.resolve(
            config: config,
            serverOverride: settings.serverOverride(
                for: config.language
            )
        )
    }

    private func statusSummary(
        _ resolution: LanguageServerResolution
    ) -> LocalizedStringKey {
        switch resolution {
        case .resolved:
            return "settings.lsp.status.resolved"
        case .notFound:
            return "settings.lsp.status.notFound"
        case .invalidOverride:
            return "settings.lsp.status.invalid"
        }
    }

    private func languageName(_ language: String) -> LocalizedStringKey {
        switch language {
        case "swift":
            return "settings.lsp.language.swift"
        case "typescript":
            return "settings.lsp.language.typescript"
        case "python":
            return "settings.lsp.language.python"
        default:
            return LocalizedStringKey(language)
        }
    }

    private func validationMessage(
        _ error: LSPSettingsValidationError
    ) -> LocalizedStringKey {
        switch error {
        case .unsupportedLanguage:
            return "settings.lsp.error.unsupported"
        case .pathMustBeAbsolute:
            return "settings.lsp.error.absolutePath"
        case .pathDoesNotExist:
            return "settings.lsp.error.notFound"
        case .pathIsDirectory:
            return "settings.lsp.error.directory"
        case .pathNotExecutable:
            return "settings.lsp.error.notExecutable"
        case .invalidPathCharacters:
            return "settings.lsp.error.pathCharacters"
        case .invalidArgument(let index):
            return "settings.lsp.error.argument \(index + 1)"
        }
    }
}

// MARK: - Draft model

/// In-memory, per-language edit state. Held only while Settings is open and
/// the fields have not yet validated into a persisted override. Invalid
/// partial text lives here with an inline `error` so it is never lost when
/// the language selection changes.
@MainActor
private struct LSPSettingsDraft {
    var executablePath: String
    var usesCustomArguments: Bool
    var argumentsText: String
    var error: LSPSettingsValidationError?
}

// MARK: - Executable picker

/// Presents an `NSOpenPanel` restricted to executable files so the user can
/// pick a language-server binary without typing an error-prone path. Runs on
/// the main actor as a sheet owned by the Settings window. Issue #1242.
@MainActor
private final class ExecutablePicker: NSObject, NSOpenSavePanelDelegate {
    private let completion: (URL) -> Void

    init(completion: @escaping (URL) -> Void) {
        self.completion = completion
    }

    func present(context: DialogPresentationContext) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        // The system can't reliably pre-filter executables by type, so we
        // validate in `panel(_:validate:)` instead and reject non-executable
        // selections with a sheet-level error.
        panel.delegate = self
        panel.prompt = Strings.lspChooseExecutablePrompt
        Task { @MainActor [weak self] in
            let response = await panel.runSheet(on: context)
            guard response == .OK,
                  let url = panel.url else {
                return
            }
            self?.completion(url)
        }
    }

    nonisolated func panel(
        _ sender: Any,
        shouldEnable url: URL
    ) -> Bool {
        if url.hasDirectoryPath { return true }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
