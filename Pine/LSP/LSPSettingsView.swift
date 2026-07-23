//
//  LSPSettingsView.swift
//  Pine
//

import AppKit
import SwiftUI

/// Native macOS Settings pane for global and per-language LSP configuration.
struct LSPSettingsView: View {
    let settings: LSPSettings
    private let resolver: any LanguageServerResolving
    private let locale: Locale

    @State private var selectedLanguage: String
    @State private var executablePath: String
    @State private var usesCustomArguments: Bool
    @State private var argumentsText: String
    @State private var validationError: LSPSettingsValidationError?

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
        let language = config?.language ?? ""
        let serverOverride = settings.serverOverride(for: language)
        _selectedLanguage = State(initialValue: language)
        _executablePath = State(
            initialValue: serverOverride?.executablePath ?? ""
        )
        _usesCustomArguments = State(
            initialValue: serverOverride?.arguments != nil
        )
        _argumentsText = State(
            initialValue: (
                serverOverride?.arguments ?? config?.arguments ?? []
            ).joined(separator: "\n")
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

                TextField(
                    "settings.lsp.executable",
                    text: $executablePath,
                    prompt: Text(Strings.lspExecutablePlaceholder)
                )

                Toggle(
                    Strings.lspCustomArguments,
                    isOn: $usesCustomArguments
                )

                Text(Strings.lspArgumentsHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $argumentsText)
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
                    .disabled(!usesCustomArguments)
                    .opacity(usesCustomArguments ? 1 : 0.55)

                Label(
                    Strings.lspDirectLaunchHelp,
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if let validationError {
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
                        loadDraft(for: config.language)
                    }
                    .disabled(
                        settings.serverOverride(
                            for: config.language
                        ) == nil
                    )

                    Spacer()

                    Button(Strings.lspApply) {
                        applyDraft(for: config)
                    }
                    .keyboardShortcut(.defaultAction)
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

    private var selectedConfig: LanguageServerConfig? {
        LanguageServerRegistry.server(forLanguage: selectedLanguage)
    }

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

    private func loadDraft(for language: String) {
        guard let config = LanguageServerRegistry.server(
            forLanguage: language
        ) else {
            return
        }
        let serverOverride = settings.serverOverride(for: language)
        executablePath = serverOverride?.executablePath ?? ""
        usesCustomArguments = serverOverride?.arguments != nil
        argumentsText = (
            serverOverride?.arguments ?? config.arguments
        ).joined(separator: "\n")
        validationError = nil
    }

    private func applyDraft(for config: LanguageServerConfig) {
        let arguments: [String]? = usesCustomArguments
            ? parsedArguments
            : nil
        do {
            try settings.setServerOverride(
                language: config.language,
                executablePath: executablePath,
                arguments: arguments
            )
            loadDraft(for: config.language)
        } catch let error as LSPSettingsValidationError {
            validationError = error
        } catch {
            validationError = .invalidPathCharacters
        }
    }

    /// Each line is one literal process argument. No quote expansion,
    /// interpolation, or shell tokenization is performed.
    private var parsedArguments: [String] {
        guard !argumentsText.isEmpty else { return [] }
        var lines = argumentsText.components(separatedBy: "\n")
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
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
