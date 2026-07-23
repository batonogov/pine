//
//  LSPSettings.swift
//  Pine
//
//  Persisted, application-wide Language Server Protocol preferences.
//

import Foundation

/// A user-supplied launch override for one supported language.
///
/// `nil` fields inherit the registry default. An explicit empty arguments
/// array means “launch without arguments”.
nonisolated struct LanguageServerOverride: Codable, Equatable, Sendable {
    let executablePath: String?
    let arguments: [String]?
}

/// A validated executable and argument vector. The process is always launched
/// directly from these values; they are never combined into a shell command.
nonisolated struct LanguageServerLaunchConfiguration: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
}

/// Why a persisted or newly-entered server override is unsafe to use.
nonisolated enum LSPSettingsValidationError: Error, Equatable, Sendable {
    case unsupportedLanguage
    case pathMustBeAbsolute
    case pathDoesNotExist
    case pathIsDirectory
    case pathNotExecutable
    case invalidPathCharacters
    case invalidArgument(index: Int)
}

/// Result shown in Settings and consumed by `LSPManager`.
nonisolated enum LanguageServerResolution: Equatable, Sendable {
    case resolved(LanguageServerLaunchConfiguration)
    case notFound(command: String)
    case invalidOverride(LSPSettingsValidationError)

    var launchConfiguration: LanguageServerLaunchConfiguration? {
        guard case .resolved(let configuration) = self else { return nil }
        return configuration
    }
}

/// A persisted change that needs to be applied to every open project.
nonisolated enum LSPSettingsChange: Equatable, Sendable {
    case enabled(Bool)
    case language(String)
}

@MainActor
protocol LSPSettingsObserver: AnyObject {
    func lspSettingsDidChange(_ change: LSPSettingsChange)
}

@MainActor
private final class WeakLSPSettingsObserver {
    weak var value: (any LSPSettingsObserver)?

    init(_ value: any LSPSettingsObserver) {
        self.value = value
    }
}

/// Pure input validation shared by the Settings model and runtime resolver.
nonisolated enum LSPSettingsValidator {
    static func validate(
        _ serverOverride: LanguageServerOverride,
        fileManager: FileManager = .default
    ) throws {
        if let path = serverOverride.executablePath {
            try validateExecutablePath(path, fileManager: fileManager)
        }

        for (index, argument) in (serverOverride.arguments ?? []).enumerated()
            where argument.contains("\0")
                || argument.contains("\n")
                || argument.contains("\r") {
            throw LSPSettingsValidationError.invalidArgument(index: index)
        }
    }

    static func validateExecutablePath(
        _ path: String,
        fileManager: FileManager = .default
    ) throws {
        guard !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r") else {
            throw LSPSettingsValidationError.invalidPathCharacters
        }
        guard (path as NSString).isAbsolutePath else {
            throw LSPSettingsValidationError.pathMustBeAbsolute
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw LSPSettingsValidationError.pathDoesNotExist
        }
        guard !isDirectory.boolValue else {
            throw LSPSettingsValidationError.pathIsDirectory
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw LSPSettingsValidationError.pathNotExecutable
        }
    }
}

/// Global LSP preferences shared by all projects.
///
/// Mutations go through methods so persistence and project lifecycle fan-out
/// cannot be bypassed accidentally.
@MainActor
@Observable
final class LSPSettings {
    static let shared = LSPSettings()

    enum Keys {
        static let enabled = "lsp.enabled"
        static let overrides = "lsp.serverOverrides.v1"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager

    private(set) var isEnabled: Bool
    private(set) var overrides: [String: LanguageServerOverride]

    @ObservationIgnored
    private var observers: [WeakLSPSettingsObserver] = []

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.isEnabled = (defaults.object(forKey: Keys.enabled) as? Bool) ?? true

        if let data = defaults.data(forKey: Keys.overrides),
           let decoded = try? JSONDecoder().decode(
               [String: LanguageServerOverride].self,
               from: data
           ) {
            let supported = Set(LanguageServerRegistry.supportedLanguages)
            self.overrides = decoded.filter { supported.contains($0.key) }
        } else {
            self.overrides = [:]
        }
    }

    func serverOverride(for language: String) -> LanguageServerOverride? {
        overrides[language]
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
        notify(.enabled(enabled))
    }

    /// Validates and persists one language's optional direct-launch override.
    ///
    /// Blank paths are normalized to `nil`. When neither field is overridden,
    /// the entry is removed so future registry defaults are inherited.
    func setServerOverride(
        language: String,
        executablePath: String?,
        arguments: [String]?
    ) throws {
        guard LanguageServerRegistry.server(forLanguage: language) != nil else {
            throw LSPSettingsValidationError.unsupportedLanguage
        }

        let normalizedPath = executablePath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let serverOverride = LanguageServerOverride(
            executablePath: normalizedPath?.isEmpty == false ? normalizedPath : nil,
            arguments: arguments
        )
        try LSPSettingsValidator.validate(
            serverOverride,
            fileManager: fileManager
        )

        let newValue: LanguageServerOverride? =
            serverOverride.executablePath == nil
                && serverOverride.arguments == nil
                ? nil
                : serverOverride
        guard overrides[language] != newValue else { return }
        overrides[language] = newValue
        persistOverrides()
        notify(.language(language))
    }

    func resetServerOverride(language: String) {
        guard overrides.removeValue(forKey: language) != nil else { return }
        persistOverrides()
        notify(.language(language))
    }

    func addObserver(_ observer: any LSPSettingsObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(WeakLSPSettingsObserver(observer))
    }

    private func persistOverrides() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Keys.overrides)
    }

    private func notify(_ change: LSPSettingsChange) {
        observers.removeAll { $0.value == nil }
        for observer in observers {
            observer.value?.lspSettingsDidChange(change)
        }
    }
}
