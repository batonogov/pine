//
//  SecretDetector.swift
//  Pine
//
//  Detects secrets (API keys, tokens, passwords) in source text using
//  regex patterns and Shannon entropy analysis.
//

import Foundation

// MARK: - SecretMatch

/// A detected secret range in the editor text.
struct SecretMatch: Equatable {
    /// The range of the secret value in the source string (not the key).
    let range: NSRange
    /// Human-readable label describing the secret type.
    let kind: String
}

// MARK: - SecretDetector

enum SecretDetector {

    // MARK: - Known patterns

    private struct Pattern {
        let regex: NSRegularExpression
        let kind: String
        /// Capture group index for the secret value (0 = full match).
        let valueGroup: Int
    }

    private static let patterns: [Pattern] = buildPatterns()

    private static func buildPatterns() -> [Pattern] {
        let defs: [(String, String, Int)] = [
            // AWS Access Key ID: AKIA + 16 uppercase alphanumeric characters
            (#"(AKIA[A-Z0-9]{16})"#, "AWS Access Key", 1),
            // GitHub tokens (classic and fine-grained)
            (#"(gh[pousr]_[A-Za-z0-9_]{36,255})"#, "GitHub Token", 1),
            (#"(github_pat_[A-Za-z0-9_]{82})"#, "GitHub Fine-Grained PAT", 1),
            // PEM private keys
            (#"(-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----)"#, "Private Key", 1),
            // Generic key/value assignments: password = "...", token = '...', api_key = `...`
            (
                #"(?i)(?:password|passwd|secret|token|api[_-]?key|auth[_-]?token|access[_-]?key|private[_-]?key|client[_-]?secret)\s*[:=]\s*["'`]([^"'`]{20,}?)["'`]"#,
                "Secret Assignment",
                1
            ),
        ]

        return defs.compactMap { (pattern, kind, group) in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Pattern(regex: regex, kind: kind, valueGroup: group)
        }
    }

    // MARK: - Entropy thresholds

    /// Minimum Shannon entropy (bits/char) to flag a quoted string as a secret.
    static let entropyThreshold: Double = 3.5
    /// Minimum length of quoted string for entropy analysis.
    private static let entropyMinLength = 20

    /// Regex that captures quoted strings for entropy scanning.
    private static let quotedStringRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"["'`]([A-Za-z0-9/+\-_.~]{20,})["'`]"#)
    }()

    // MARK: - Public API

    /// Scans `text` and returns all detected secret ranges.
    /// Results are deduplicated — overlapping matches keep the first one found.
    static func detect(in text: String) -> [SecretMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var matches: [SecretMatch] = []

        // Pattern-based detection
        for pattern in patterns {
            let results = pattern.regex.matches(in: text, range: fullRange)
            for result in results {
                let groupIndex = pattern.valueGroup
                guard groupIndex < result.numberOfRanges else { continue }
                let range = result.range(at: groupIndex)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                matches.append(SecretMatch(range: range, kind: pattern.kind))
            }
        }

        // Entropy-based detection: scan quoted strings not already flagged
        let entropyResults = quotedStringRegex.matches(in: text, range: fullRange)
        for result in entropyResults {
            guard result.numberOfRanges > 1 else { continue }
            let valueRange = result.range(at: 1)
            guard valueRange.location != NSNotFound, valueRange.length >= entropyMinLength else { continue }
            let value = nsText.substring(with: valueRange)
            if shannonEntropy(value) >= entropyThreshold {
                matches.append(SecretMatch(range: valueRange, kind: "High-Entropy String"))
            }
        }

        return deduplicated(matches)
    }

    // MARK: - Entropy calculation

    /// Computes Shannon entropy in bits per character.
    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for ch in s { freq[ch, default: 0] += 1 }
        let len = Double(s.count)
        return freq.values.reduce(0.0) { acc, count in
            let p = Double(count) / len
            return acc - p * log2(p)
        }
    }

    // MARK: - Staged files scanning

    /// Scans git-staged files in `projectURL` for secrets.
    /// Returns a list of `(relativePath, matches)` for each file that contains at least one secret.
    static func scanStagedFiles(at projectURL: URL) -> [(path: String, matches: [SecretMatch])] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", projectURL.path, "diff", "--cached", "--name-only"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        let paths = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var results: [(path: String, matches: [SecretMatch])] = []
        for relativePath in paths {
            let fileURL = projectURL.appendingPathComponent(relativePath)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let fileMatches = detect(in: text)
            if !fileMatches.isEmpty {
                results.append((path: relativePath, matches: fileMatches))
            }
        }
        return results
    }

    // MARK: - Helpers

    /// Removes duplicate/overlapping matches, keeping the first occurrence.
    static func deduplicated(_ matches: [SecretMatch]) -> [SecretMatch] {
        var result: [SecretMatch] = []
        for match in matches {
            let overlaps = result.contains { existing in
                NSIntersectionRange(existing.range, match.range).length > 0
            }
            if !overlaps {
                result.append(match)
            }
        }
        return result
    }
}
