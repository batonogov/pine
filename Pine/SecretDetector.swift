//
//  SecretDetector.swift
//  Pine
//

import Foundation

// MARK: - Models

/// The kind of secret pattern that was detected.
enum SecretKind: Equatable, Sendable {
    case awsAccessKey
    case githubToken
    case privateKeyHeader
    case genericAssignment(key: String)
    case highEntropy
}

extension SecretKind {
    var displayName: String {
        switch self {
        case .awsAccessKey: return "AWS Access Key"
        case .githubToken: return "GitHub Token"
        case .privateKeyHeader: return "Private Key"
        case .genericAssignment(let key): return "Secret assignment (\(key))"
        case .highEntropy: return "High-entropy secret"
        }
    }
}

/// A detected secret within a string, with its range and kind.
struct SecretMatch: Equatable, Sendable {
    /// The range within the scanned NSString (UTF-16 offsets).
    let range: NSRange
    let kind: SecretKind
}

// MARK: - SecretDetector

/// Scans text for patterns indicating embedded secrets (API keys, tokens, passwords).
/// Detection is purely read-only — the source text is never modified.
final class SecretDetector: @unchecked Sendable {
    static let shared = SecretDetector()

    // MARK: - Compiled patterns

    /// AWS Access Key ID: `AKIA` followed by exactly 16 uppercase alphanumeric chars.
    private let awsKeyRegex = try? NSRegularExpression(
        pattern: #"\bAKIA[0-9A-Z]{16}\b"#
    )

    /// GitHub tokens: `ghp_`, `gho_`, `ghs_`, `ghu_`, `ghr_` prefixes.
    private let githubTokenRegex = try? NSRegularExpression(
        pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#
    )

    /// GitHub fine-grained personal access tokens.
    private let githubFineGrainedRegex = try? NSRegularExpression(
        pattern: #"\bgithub_pat_[A-Za-z0-9_]{82}\b"#
    )

    /// PEM private key block headers.
    private let privateKeyRegex = try? NSRegularExpression(
        pattern: #"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"#
    )

    /// Generic assignment: `key = "long_value"` or `key: 'long_value'` (≥ 20 chars).
    /// Group 1 = key name, group 2 = value.
    private let genericAssignmentRegex: NSRegularExpression? = {
        let keyNames = "(?:password|passwd|pwd|secret|token|api[-_]?key|auth[-_]?token"
            + "|access[-_]?key|private[-_]?key|client[-_]?secret|bearer)"
        let pattern = "(?i)\\b(\(keyNames))\\s*(?:=|:)\\s*['\"]([^'\"]{20,})['\"]"
        return try? NSRegularExpression(pattern: pattern)
    }()

    /// High-entropy assignment detector (used to catch non-pattern secrets).
    private let entropyAssignmentRegex: NSRegularExpression? = {
        let keyNames = "(?:password|token|secret|key|auth)"
        let pattern = "(?i)\\b\(keyNames)\\s*(?:=|:)\\s*['\"]([^'\"]{20,})['\"]"
        return try? NSRegularExpression(pattern: pattern)
    }()

    private init() {}

    // MARK: - Public API

    /// Returns all detected secret matches in `text`, sorted by range location.
    /// Overlapping matches are deduplicated, with the first (earlier) match winning.
    func detect(in text: String) -> [SecretMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var matches: [SecretMatch] = []

        // AWS access keys
        if let re = awsKeyRegex {
            for result in re.matches(in: text, range: fullRange) {
                matches.append(SecretMatch(range: result.range, kind: .awsAccessKey))
            }
        }

        // GitHub tokens (short prefix)
        if let re = githubTokenRegex {
            for result in re.matches(in: text, range: fullRange) {
                matches.append(SecretMatch(range: result.range, kind: .githubToken))
            }
        }

        // GitHub fine-grained PAT
        if let re = githubFineGrainedRegex {
            for result in re.matches(in: text, range: fullRange) {
                matches.append(SecretMatch(range: result.range, kind: .githubToken))
            }
        }

        // PEM private key headers
        if let re = privateKeyRegex {
            for result in re.matches(in: text, range: fullRange) {
                matches.append(SecretMatch(range: result.range, kind: .privateKeyHeader))
            }
        }

        // Generic key=value assignment — highlight only the value (group 2)
        if let re = genericAssignmentRegex {
            for result in re.matches(in: text, range: fullRange) {
                let keyRange = result.range(at: 1)
                let valRange = result.range(at: 2)
                guard keyRange.location != NSNotFound, valRange.location != NSNotFound,
                      let swiftKeyRange = Range(keyRange, in: text) else { continue }
                let key = String(text[swiftKeyRange]).lowercased()
                matches.append(SecretMatch(range: valRange, kind: .genericAssignment(key: key)))
            }
        }

        // Entropy-based detection for values not caught above
        let entropyMatches = detectHighEntropySecrets(in: text, fullRange: fullRange)
        matches.append(contentsOf: entropyMatches)

        // Sort by location and remove overlaps
        let sorted = matches.sorted { $0.range.location < $1.range.location }
        return deduplicating(sorted)
    }

    // MARK: - Entropy detection

    /// Detects high-entropy (≥ 3.5 bits/char) quoted strings in assignment context
    /// that were not already caught by the named patterns.
    private func detectHighEntropySecrets(in text: String, fullRange: NSRange) -> [SecretMatch] {
        guard let re = entropyAssignmentRegex else { return [] }
        var results: [SecretMatch] = []
        for result in re.matches(in: text, range: fullRange) {
            // entropyAssignmentRegex has one capturing group (at index 1): the value.
            let valRange = result.range(at: 1)
            guard valRange.location != NSNotFound,
                  let swiftRange = Range(valRange, in: text) else { continue }
            let value = String(text[swiftRange])
            guard Self.shannonEntropy(value) >= 3.5 else { continue }
            results.append(SecretMatch(range: valRange, kind: .highEntropy))
        }
        return results
    }

    // MARK: - Utilities

    /// Computes the Shannon entropy (bits per character) of a string.
    /// H = −∑ p(c) × log₂(p(c))
    static func shannonEntropy(_ string: String) -> Double {
        guard !string.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for char in string { freq[char, default: 0] += 1 }
        let length = Double(string.count)
        return freq.values.reduce(0.0) { sum, count in
            let p = Double(count) / length
            return sum - p * log2(p)
        }
    }

    /// Removes matches whose ranges overlap a previously seen match.
    /// Input must be sorted by `range.location`.
    private func deduplicating(_ sorted: [SecretMatch]) -> [SecretMatch] {
        var result: [SecretMatch] = []
        var lastEnd = 0
        for match in sorted {
            guard match.range.location >= lastEnd else { continue }
            result.append(match)
            lastEnd = match.range.location + match.range.length
        }
        return result
    }
}

// MARK: - Staged file scanning

extension SecretDetector {
    /// Result of scanning staged files for secrets.
    struct StagedSecretResult {
        /// Relative path within the repository.
        let filePath: String
        let matches: [SecretMatch]
    }

    /// Scans all staged (index) files at `repositoryURL` for secrets.
    /// Uses `git diff --cached --name-only` to enumerate staged files,
    /// then reads each from the working tree and scans it.
    /// Binary files and files larger than 1 MB are skipped.
    /// Returns results only for files that contain at least one match.
    static func scanStagedFiles(at repositoryURL: URL) -> [StagedSecretResult] {
        let result = GitStatusProvider.runGit(
            ["diff", "--cached", "--name-only", "--diff-filter=ACMR"],
            at: repositoryURL
        )
        guard result.exitCode == 0 else { return [] }

        let filePaths = result.output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var stagedResults: [StagedSecretResult] = []
        let detector = SecretDetector.shared
        let maxFileSize = 1_024 * 1_024 // 1 MB

        for relativePath in filePaths {
            let fileURL = repositoryURL.appendingPathComponent(relativePath)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? Int,
                  size <= maxFileSize else { continue }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let matches = detector.detect(in: text)
            if !matches.isEmpty {
                stagedResults.append(StagedSecretResult(filePath: relativePath, matches: matches))
            }
        }
        return stagedResults
    }
}
