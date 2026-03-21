//
//  SecretDetectorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct SecretDetectorTests {

    private let detector = SecretDetector.shared

    // MARK: - AWS Access Keys

    @Test func detectsAwsAccessKey() {
        let text = "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"
        let matches = detector.detect(in: text)
        #expect(matches.count == 1)
        #expect(matches[0].kind == .awsAccessKey)
    }

    @Test func doesNotDetectShortAwsLikeString() {
        // AKIA + fewer than 16 chars — not a valid AWS key
        let text = "AKIASHORT"
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    @Test func detectsAwsAccessKeyInMultilineText() {
        let text = """
        [default]
        aws_access_key_id = AKIAIOSFODNN7EXAMPLE
        aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
        """
        let matches = detector.detect(in: text)
        let awsMatches = matches.filter { $0.kind == .awsAccessKey }
        #expect(awsMatches.count == 1)
    }

    // MARK: - GitHub Tokens

    @Test func detectsGithubPersonalAccessToken() {
        // ghp_ prefix, 36 alphanumeric chars
        let token = "ghp_" + String(repeating: "a", count: 36)
        let text = "GITHUB_TOKEN=\(token)"
        let matches = detector.detect(in: text)
        let ghMatches = matches.filter { $0.kind == .githubToken }
        #expect(!ghMatches.isEmpty)
    }

    @Test func detectsGithubOauthToken() {
        let token = "gho_" + String(repeating: "B", count: 36)
        let text = "token: \(token)"
        let matches = detector.detect(in: text)
        let ghMatches = matches.filter { $0.kind == .githubToken }
        #expect(!ghMatches.isEmpty)
    }

    @Test func doesNotDetectShortGithubLikeString() {
        // Too short to be a GitHub token
        let text = "ghp_abc123"
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    // MARK: - Private Key Headers

    @Test func detectsRsaPrivateKey() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
        let matches = detector.detect(in: text)
        let pkMatches = matches.filter { $0.kind == .privateKeyHeader }
        #expect(pkMatches.count == 1)
    }

    @Test func detectsGenericPrivateKey() {
        let text = "-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----"
        let matches = detector.detect(in: text)
        let pkMatches = matches.filter { $0.kind == .privateKeyHeader }
        #expect(pkMatches.count == 1)
    }

    @Test func detectsOpenSshPrivateKey() {
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----"
        let matches = detector.detect(in: text)
        let pkMatches = matches.filter { $0.kind == .privateKeyHeader }
        #expect(pkMatches.count == 1)
    }

    // MARK: - Generic Assignment Pattern

    @Test func detectsPasswordAssignment() {
        let text = #"password = "mysupersecretpassword123""#
        let matches = detector.detect(in: text)
        let assignMatches = matches.filter {
            if case .genericAssignment = $0.kind { return true }
            return false
        }
        #expect(!assignMatches.isEmpty)
    }

    @Test func detectsTokenAssignment() {
        let text = #"token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload""#
        let matches = detector.detect(in: text)
        #expect(!matches.isEmpty)
    }

    @Test func detectsApiKeyAssignment() {
        let text = #"api_key = "sk-abcdefghijklmnopqrstuvwxyz1234""#
        let matches = detector.detect(in: text)
        #expect(!matches.isEmpty)
    }

    @Test func ignoresShortAssignmentValues() {
        // Value shorter than 20 chars — should not be flagged
        let text = #"password = "short""#
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    @Test func ignoresNonSecretAssignments() {
        let text = #"username = "john.doe@example.com""#
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    // MARK: - Deduplication

    @Test func deduplicatesOverlappingMatches() {
        // A generic assignment that also triggers entropy detection
        // should produce only one match (not two for the same range)
        let secret = String(repeating: "aB3xY9", count: 4) // 24 chars, high entropy
        let text = #"token = "\#(secret)""#
        let matches = detector.detect(in: text)
        // Verify no two matches cover exactly the same range
        for (i, m1) in matches.enumerated() {
            for (j, m2) in matches.enumerated() where i != j {
                #expect(m1.range.location != m2.range.location)
            }
        }
    }

    @Test func noOverlappingRanges() {
        let text = """
        password = "supersecretvalue12345"
        token = "anothersecretvalue6789"
        """
        let matches = detector.detect(in: text)
        var lastEnd = 0
        for match in matches {
            #expect(match.range.location >= lastEnd)
            lastEnd = match.range.location + match.range.length
        }
    }

    // MARK: - Shannon Entropy

    @Test func entropyOfEmptyStringIsZero() {
        #expect(SecretDetector.shannonEntropy("") == 0)
    }

    @Test func entropyOfRepeatedCharIsZero() {
        #expect(SecretDetector.shannonEntropy("aaaa") == 0)
    }

    @Test func entropyOfTwoSymbolsIsOne() {
        // "abab" → 2 symbols, each 50% → H = 1.0
        let entropy = SecretDetector.shannonEntropy("abab")
        #expect(abs(entropy - 1.0) < 0.001)
    }

    @Test func highEntropyStringAboveThreshold() {
        // A realistic API key with mixed chars should be > 3.5
        let entropy = SecretDetector.shannonEntropy("aB3xY9zQ1mN7kR5pT0sW")
        #expect(entropy > 3.5)
    }

    @Test func lowEntropyStringBelowThreshold() {
        // A dictionary word repeated — low entropy
        let entropy = SecretDetector.shannonEntropy("passwordpassword")
        #expect(entropy < 3.5)
    }

    // MARK: - Empty / Plain text

    @Test func emptyStringYieldsNoMatches() {
        #expect(detector.detect(in: "").isEmpty)
    }

    @Test func plainTextYieldsNoMatches() {
        let text = "let x = 42\nprint(x)"
        #expect(detector.detect(in: text).isEmpty)
    }

    @Test func commentedSecretIsStillDetected() {
        // Secret detector is pattern-based; it does not distinguish comments
        let text = #"// password = "supersecretvalue12345""#
        let matches = detector.detect(in: text)
        #expect(!matches.isEmpty)
    }

    // MARK: - Staged files scanning

    @Test func scanStagedFilesReturnsEmptyForNonGitDirectory() {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let results = SecretDetector.scanStagedFiles(at: tmpDir)
        #expect(results.isEmpty)
    }

    // MARK: - SecretKind display names

    @Test func awsKindHasDisplayName() {
        #expect(!SecretKind.awsAccessKey.displayName.isEmpty)
    }

    @Test func githubKindHasDisplayName() {
        #expect(!SecretKind.githubToken.displayName.isEmpty)
    }

    @Test func privateKeyKindHasDisplayName() {
        #expect(!SecretKind.privateKeyHeader.displayName.isEmpty)
    }

    @Test func genericAssignmentKindHasDisplayName() {
        let kind = SecretKind.genericAssignment(key: "password")
        #expect(kind.displayName.contains("password"))
    }

    @Test func highEntropyKindHasDisplayName() {
        #expect(!SecretKind.highEntropy.displayName.isEmpty)
    }

    // MARK: - SecretMaskingSettings

    private func freshDefaults(suite: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func secretMaskingSettingsDefaults() {
        let settings = SecretMaskingSettings(defaults: freshDefaults(suite: "pine-test-secret-masking"))
        #expect(settings.isEnabled == true)
    }

    @Test func secretMaskingSettingsToggle() {
        let settings = SecretMaskingSettings(defaults: freshDefaults(suite: "pine-test-secret-toggle"))
        let initial = settings.isEnabled
        settings.toggle()
        #expect(settings.isEnabled == !initial)
        settings.toggle()
        #expect(settings.isEnabled == initial)
    }

    @Test func secretMaskingSettingsEnableDisable() {
        let settings = SecretMaskingSettings(defaults: freshDefaults(suite: "pine-test-secret-enable"))
        settings.disable()
        #expect(settings.isEnabled == false)
        settings.enable()
        #expect(settings.isEnabled == true)
    }
}
