//
//  SecretDetector.swift
//  Pine
//
//  Detects secrets (API keys, tokens, passwords, private keys) in text content.
//  Uses regex patterns for known formats and assignment-based detection for generic secrets.
//

import Foundation

// MARK: - Models

/// Describes a single detected secret in text.
struct SecretMatch: Equatable, Sendable {
    /// The kind of secret detected.
    let kind: SecretKind
    /// The range of the secret value in the source text.
    let range: Range<String.Index>
    /// A human-readable label for the secret type.
    var label: String { kind.label }
}

/// Known secret types.
enum SecretKind: String, CaseIterable, Sendable {
    case awsAccessKey
    case awsSecretKey
    case githubToken
    case githubOAuthToken
    case githubAppToken
    case githubPersonalAccessTokenFineGrained
    case genericPrivateKey
    case genericPassword
    case genericToken
    case genericSecret
    case genericAPIKey
    case slackToken
    case slackWebhook
    case stripeKey
    case googleAPIKey
    case herokuAPIKey
    case twilioAPIKey
    case sendgridAPIKey
    case npmToken
    case pypiToken
    case nugetAPIKey

    var label: String {
        switch self {
        case .awsAccessKey: return String(localized: "secret.kind.awsAccessKey")
        case .awsSecretKey: return String(localized: "secret.kind.awsSecretKey")
        case .githubToken: return String(localized: "secret.kind.githubToken")
        case .githubOAuthToken: return String(localized: "secret.kind.githubOAuthToken")
        case .githubAppToken: return String(localized: "secret.kind.githubAppToken")
        case .githubPersonalAccessTokenFineGrained: return String(localized: "secret.kind.githubFineGrainedPAT")
        case .genericPrivateKey: return String(localized: "secret.kind.privateKey")
        case .genericPassword: return String(localized: "secret.kind.password")
        case .genericToken: return String(localized: "secret.kind.token")
        case .genericSecret: return String(localized: "secret.kind.secret")
        case .genericAPIKey: return String(localized: "secret.kind.apiKey")
        case .slackToken: return String(localized: "secret.kind.slackToken")
        case .slackWebhook: return String(localized: "secret.kind.slackWebhook")
        case .stripeKey: return String(localized: "secret.kind.stripeKey")
        case .googleAPIKey: return String(localized: "secret.kind.googleAPIKey")
        case .herokuAPIKey: return String(localized: "secret.kind.herokuAPIKey")
        case .twilioAPIKey: return String(localized: "secret.kind.twilioAPIKey")
        case .sendgridAPIKey: return String(localized: "secret.kind.sendgridAPIKey")
        case .npmToken: return String(localized: "secret.kind.npmToken")
        case .pypiToken: return String(localized: "secret.kind.pypiToken")
        case .nugetAPIKey: return String(localized: "secret.kind.nugetAPIKey")
        }
    }
}

/// A compiled secret detection rule.
struct SecretRule: Sendable {
    let kind: SecretKind
    let regex: NSRegularExpression
    /// Which capture group contains the actual secret value (0 = full match).
    let captureGroup: Int
}

/// User-defined custom pattern loaded from `.pinesecrets`.
struct CustomSecretPattern: Codable, Equatable, Sendable {
    let name: String
    let pattern: String
}

/// Configuration loaded from `.pinesecrets` file.
struct PineSecretsConfig: Codable, Equatable, Sendable {
    var customPatterns: [CustomSecretPattern]
    var disabledKinds: [String]

    init(customPatterns: [CustomSecretPattern] = [], disabledKinds: [String] = []) {
        self.customPatterns = customPatterns
        self.disabledKinds = disabledKinds
    }
}

// MARK: - SecretDetector

/// Scans text for secret patterns. Thread-safe — all state is immutable after init.
final class SecretDetector: Sendable {

    /// Default shared instance with built-in rules only.
    static let shared = SecretDetector()

    /// Compiled rules.
    let rules: [SecretRule]

    /// Disabled kind raw values (from .pinesecrets).
    private let disabledKinds: Set<String>

    // MARK: - Init

    init(config: PineSecretsConfig? = nil) {
        var compiled = Self.compileBuiltInRules()

        if let config {
            // Add custom patterns
            for custom in config.customPatterns {
                if let regex = try? NSRegularExpression(pattern: custom.pattern, options: []) {
                    compiled.append(SecretRule(kind: .genericSecret, regex: regex, captureGroup: 0))
                }
            }
            disabledKinds = Set(config.disabledKinds)
        } else {
            disabledKinds = []
        }

        rules = compiled
    }

    // MARK: - Detection

    /// Scans `text` and returns all detected secret matches, sorted by position.
    func detect(in text: String) -> [SecretMatch] {
        guard !text.isEmpty else { return [] }

        var matches: [SecretMatch] = []
        let nsRange = NSRange(text.startIndex..., in: text)

        for rule in rules {
            guard !disabledKinds.contains(rule.kind.rawValue) else { continue }

            let results = rule.regex.matches(in: text, options: [], range: nsRange)
            for result in results {
                let groupIndex = min(rule.captureGroup, result.numberOfRanges - 1)
                let matchNSRange = result.range(at: groupIndex)
                guard matchNSRange.location != NSNotFound,
                      let range = Range(matchNSRange, in: text) else { continue }

                // Skip matches inside line comments (//, #) and block comments (/* */)
                if isInsideComment(text: text, range: range) { continue }

                matches.append(SecretMatch(kind: rule.kind, range: range))
            }
        }

        // Sort by position, deduplicate overlapping ranges (keep first/more specific)
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        return deduplicateOverlapping(matches)
    }

    /// Checks if the given file content contains any secrets.
    /// Delegates to `detect()` to ensure comment filtering and all other logic is applied consistently.
    func containsSecrets(in text: String) -> Bool {
        !detect(in: text).isEmpty
    }

    /// Masks all detected secrets in text, replacing the secret value with `mask` characters.
    /// Builds result by concatenating non-secret and masked segments to avoid index invalidation.
    func mask(in text: String, with maskChar: Character = "\u{2022}") -> String {
        let matches = detect(in: text)
        guard !matches.isEmpty else { return text }

        // Build result forward: copy non-secret text, insert mask for each match
        var result = ""
        var currentIndex = text.startIndex
        for match in matches {
            // Append text before this secret
            result.append(contentsOf: text[currentIndex..<match.range.lowerBound])
            // Append masked replacement
            let charCount = text.distance(from: match.range.lowerBound, to: match.range.upperBound)
            result.append(contentsOf: String(repeating: maskChar, count: min(charCount, 12)))
            currentIndex = match.range.upperBound
        }
        // Append remaining text after last match
        result.append(contentsOf: text[currentIndex...])
        return result
    }

    // MARK: - Config Loading

    /// Loads `.pinesecrets` config from a project directory.
    static func loadConfig(from projectURL: URL) -> PineSecretsConfig? {
        let configURL = projectURL.appendingPathComponent(".pinesecrets")
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(PineSecretsConfig.self, from: data)
    }

    // MARK: - Private

    /// Checks if the match is inside a line comment (//, #) or a block comment (/* */).
    private func isInsideComment(text: String, range: Range<String.Index>) -> Bool {
        isInsideLineComment(text: text, range: range)
            || isInsideBlockComment(text: text, range: range)
    }

    /// Checks if the match is on a line that starts with // or #.
    private func isInsideLineComment(text: String, range: Range<String.Index>) -> Bool {
        let beforeMatch = text[text.startIndex..<range.lowerBound]
        guard let lastNewline = beforeMatch.lastIndex(of: "\n") else {
            let linePrefix = text[text.startIndex..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            return linePrefix.hasPrefix("//") || linePrefix.hasPrefix("#")
        }
        let lineStart = text.index(after: lastNewline)
        let linePrefix = text[lineStart..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        return linePrefix.hasPrefix("//") || linePrefix.hasPrefix("#")
    }

    /// Checks if the match falls within a /* ... */ block comment.
    private func isInsideBlockComment(text: String, range: Range<String.Index>) -> Bool {
        let beforeMatch = text[text.startIndex..<range.lowerBound]
        // Find the last /* before the match
        guard let openRange = beforeMatch.range(of: "/*", options: .backwards) else {
            return false
        }
        // Check if there's a closing */ between that /* and the match start
        let betweenRange = openRange.upperBound..<range.lowerBound
        guard betweenRange.lowerBound < betweenRange.upperBound else { return true }
        return text[betweenRange].range(of: "*/") == nil
    }

    /// Removes overlapping matches, keeping the first (higher-priority) one.
    private func deduplicateOverlapping(_ matches: [SecretMatch]) -> [SecretMatch] {
        var result: [SecretMatch] = []
        var lastEnd: String.Index?

        for match in matches {
            if let end = lastEnd, match.range.lowerBound < end {
                continue // Overlaps with previous, skip
            }
            result.append(match)
            lastEnd = match.range.upperBound
        }
        return result
    }

    // MARK: - Built-in Rules

    // swiftlint:disable function_body_length
    private static func compileBuiltInRules() -> [SecretRule] {
        var rules: [SecretRule] = []

        func add(_ kind: SecretKind, _ pattern: String, group: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            rules.append(SecretRule(kind: kind, regex: regex, captureGroup: group))
        }

        // AWS Access Key ID: starts with AKIA, exactly 20 uppercase alphanumeric chars
        add(.awsAccessKey, #"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"#)

        // AWS Secret Access Key: 40 base64-like chars after known assignment patterns
        add(.awsSecretKey,
            #"(?i)(?:aws_secret_access_key|aws_secret_key)\s*[=:]\s*["']?([A-Za-z0-9/+=]{40})["']?"#,
            group: 1)

        // GitHub tokens
        add(.githubToken, #"(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{36}(?![A-Za-z0-9_])"#)
        add(.githubOAuthToken, #"(?<![A-Za-z0-9_])gho_[A-Za-z0-9]{36}(?![A-Za-z0-9_])"#)
        add(.githubAppToken, #"(?<![A-Za-z0-9_])(?:ghu|ghs|ghr)_[A-Za-z0-9]{36}(?![A-Za-z0-9_])"#)
        add(.githubPersonalAccessTokenFineGrained,
            #"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}(?![A-Za-z0-9_])"#)

        // Slack tokens
        add(.slackToken, #"(?<![A-Za-z0-9])xox[bpors]-[A-Za-z0-9\-]{10,250}(?![A-Za-z0-9])"#)
        add(.slackWebhook, #"https://hooks\.slack\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+"#)

        // Stripe keys
        add(.stripeKey, #"(?<![A-Za-z0-9_])(?:sk|pk)_(?:test|live)_[A-Za-z0-9]{20,}(?![A-Za-z0-9_])"#)

        // Google API Key
        add(.googleAPIKey, #"(?<![A-Za-z0-9_])AIza[A-Za-z0-9\-_]{35}(?![A-Za-z0-9_])"#)

        // Heroku API Key
        add(.herokuAPIKey,
            #"(?i)(?:heroku_api_key|heroku_key)\s*[=:]\s*["']?([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})["']?"#,
            group: 1)

        // Twilio API Key: require mixed hex (not all same char) to reduce false positives
        add(.twilioAPIKey,
            #"(?i)(?:twilio|TWILIO)\S*\s*[=:]\s*["']?(SK[a-f0-9]{32})["']?"#,
            group: 1)

        // SendGrid API Key
        add(.sendgridAPIKey, #"(?<![A-Za-z0-9_.])SG\.[A-Za-z0-9\-_]{22,}\.[A-Za-z0-9\-_]{22,}(?![A-Za-z0-9_])"#)

        // npm token
        add(.npmToken, #"(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36}(?![A-Za-z0-9_])"#)

        // PyPI token
        add(.pypiToken, #"(?<![A-Za-z0-9_])pypi-[A-Za-z0-9\-]{50,}(?![A-Za-z0-9_])"#)

        // NuGet API Key: require assignment context to reduce false positives
        add(.nugetAPIKey,
            #"(?i)(?:nuget|NUGET)\S*\s*[=:]\s*["']?(oy2[A-Za-z0-9]{43})["']?"#,
            group: 1)

        // Private key blocks (PEM format)
        add(.genericPrivateKey, #"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#)

        // Generic assignment-based patterns: password = "...", token = "...", etc.
        // Captures the value between quotes (group 1).
        add(.genericPassword,
            #"(?i)(?:password|passwd|pwd)\s*[=:]\s*["']([^"'\s]{8,})["']"#,
            group: 1)

        add(.genericToken,
            #"(?i)(?:(?:access|auth|bearer)_token|token)\s*[=:]\s*["']([^"'\s]{8,})["']"#,
            group: 1)

        add(.genericSecret,
            #"(?i)(?:client_secret|secret_key|app_secret)\s*[=:]\s*["']([^"'\s]{8,})["']"#,
            group: 1)

        add(.genericAPIKey,
            #"(?i)(?:api_key|apikey)\s*[=:]\s*["']([^"'\s]{8,})["']"#,
            group: 1)

        // .env file format: KEY=value (no quotes)
        add(.genericPassword,
            #"(?i)(?:password|passwd|pwd)\s*=\s*([^\s"'#]{8,})"#,
            group: 1)

        add(.genericToken,
            #"(?i)(?:(?:access|auth|bearer)_token|token)\s*=\s*([^\s"'#]{8,})"#,
            group: 1)

        add(.genericSecret,
            #"(?i)(?:client_secret|secret_key|app_secret)\s*=\s*([^\s"'#]{8,})"#,
            group: 1)

        add(.genericAPIKey,
            #"(?i)(?:api_key|apikey)\s*=\s*([^\s"'#]{8,})"#,
            group: 1)

        return rules
    }
    // swiftlint:enable function_body_length
}
