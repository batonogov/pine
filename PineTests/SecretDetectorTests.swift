//
//  SecretDetectorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct SecretDetectorTests {

    let detector = SecretDetector()

    // MARK: - AWS Access Key

    @Test func detectsAWSAccessKey() {
        let text = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .awsAccessKey })
    }

    @Test func awsAccessKeyMustBe20Chars() {
        // Too short — only 15 chars after AKIA
        let text = "AKIAIOSFODNN7EX"
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .awsAccessKey })
    }

    @Test func awsAccessKeyBoundary() {
        // Embedded in longer string — should NOT match
        let text = "prefixAKIAIOSFODNN7EXAMPLEsuffix"
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .awsAccessKey })
    }

    @Test func detectsAWSSecretKey() {
        let text = #"aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .awsSecretKey })
    }

    // MARK: - GitHub Tokens

    @Test func detectsGitHubPersonalAccessToken() {
        let text = "token = ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .githubToken })
    }

    @Test func detectsGitHubOAuthToken() {
        let text = "GITHUB_TOKEN=gho_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .githubOAuthToken })
    }

    @Test func detectsGitHubAppTokens() {
        let ghu = "ghu_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let ghs = "ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let ghr = "ghr_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        for token in [ghu, ghs, ghr] {
            let matches = detector.detect(in: token)
            #expect(matches.contains { $0.kind == .githubAppToken }, "Should detect \(token)")
        }
    }

    @Test func detectsGitHubFineGrainedPAT() {
        // Format: github_pat_ + 22 alnum + _ + 59 alnum
        let token = "github_pat_" + String(repeating: "A", count: 22) + "_" + String(repeating: "B", count: 59)
        let matches = detector.detect(in: token)
        #expect(matches.contains { $0.kind == .githubPersonalAccessTokenFineGrained })
    }

    @Test func githubTokenBoundary() {
        // Should not match when embedded
        let text = "prefix_ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .githubToken })
    }

    // MARK: - Slack Tokens

    @Test func detectsSlackBotToken() {
        let text = "SLACK_TOKEN=xoxb-1234567890-abcdefghij"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .slackToken })
    }

    @Test func detectsSlackWebhook() {
        let text = "https://hooks.slack.com/services/T12345678/B12345678/abcdefghijklmnop"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .slackWebhook })
    }

    // MARK: - Stripe Keys

    @Test func detectsStripeLiveKey() {
        // Use pattern that matches Stripe format but is clearly fake
        let text = "sk_test_FAKEFAKEFAKEFAKEFAKE"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .stripeKey })
    }

    @Test func detectsStripeTestKey() {
        let text = "pk_test_FAKEFAKEFAKEFAKEFAKE"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .stripeKey })
    }

    // MARK: - Google API Key

    @Test func detectsGoogleAPIKey() {
        let text = "AIzaSyC_abcdefghij1234567890-ABCDEFGHIJ"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .googleAPIKey })
    }

    // MARK: - Heroku API Key

    @Test func detectsHerokuAPIKey() {
        let text = #"heroku_api_key = "a1b2c3d4-e5f6-7890-abcd-ef1234567890""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .herokuAPIKey })
    }

    // MARK: - Twilio

    @Test func detectsTwilioAPIKey() {
        // SK + 32 hex chars with twilio context
        let key = "SK" + String(repeating: "f", count: 16) + String(repeating: "0", count: 16)
        let text = "TWILIO_API_KEY = \(key)"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .twilioAPIKey })
    }

    @Test func twilioWithoutContextDoesNotMatch() {
        // Bare SK + 32 hex without twilio keyword — should not match
        let text = "SK" + String(repeating: "f", count: 16) + String(repeating: "0", count: 16)
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .twilioAPIKey })
    }

    // MARK: - SendGrid

    @Test func detectsSendGridAPIKey() {
        let text = "SG.abc123-def456_ghi789jklmn.opqrst-uvwxyz_ABCDEFGHIJ"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .sendgridAPIKey })
    }

    // MARK: - npm Token

    @Test func detectsNpmToken() {
        let text = "npm_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .npmToken })
    }

    // MARK: - PyPI Token

    @Test func detectsPyPIToken() {
        let token = "pypi-" + String(repeating: "a", count: 50)
        let matches = detector.detect(in: token)
        #expect(matches.contains { $0.kind == .pypiToken })
    }

    // MARK: - NuGet API Key

    @Test func detectsNuGetAPIKey() {
        let key = "oy2" + String(repeating: "A", count: 43)
        let text = "NUGET_API_KEY = \(key)"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .nugetAPIKey })
    }

    @Test func nugetWithoutContextDoesNotMatch() {
        let text = "oy2" + String(repeating: "A", count: 43)
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .nugetAPIKey })
    }

    // MARK: - Private Key

    @Test func detectsRSAPrivateKey() {
        let text = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIBogIBAAJBALRn...
        -----END RSA PRIVATE KEY-----
        """
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPrivateKey })
    }

    @Test func detectsGenericPrivateKey() {
        let text = "-----BEGIN PRIVATE KEY-----"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPrivateKey })
    }

    @Test func detectsECPrivateKey() {
        let text = "-----BEGIN EC PRIVATE KEY-----"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPrivateKey })
    }

    @Test func detectsOpenSSHPrivateKey() {
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPrivateKey })
    }

    // MARK: - Generic Assignment Patterns

    @Test func detectsPasswordAssignment() {
        let text = #"password = "SuperSecret123""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    @Test func detectsPasswordWithColon() {
        let text = #"password: "MyP@ssword!""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    @Test func detectsPwdVariant() {
        let text = #"pwd = "x9k3mZq!p""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    @Test func detectsTokenAssignment() {
        let text = #"access_token = "eyJhbGciOiJIUzI1NiJ9""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericToken })
    }

    @Test func detectsBearerTokenAssignment() {
        let text = #"bearer_token = "abc123def456ghi789""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericToken })
    }

    @Test func detectsSecretAssignment() {
        let text = #"client_secret = "abcdef1234567890""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericSecret })
    }

    @Test func detectsAPIKeyAssignment() {
        let text = #"api_key = "abcdef1234567890""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericAPIKey })
    }

    @Test func detectsApiKeyNoDash() {
        let text = #"apikey = "abcdef1234567890""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericAPIKey })
    }

    // MARK: - Short Values (False Positives)

    @Test func ignoresShortPasswordValues() {
        // Value less than 8 chars should NOT match generic password
        let text = #"password = "short""#
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .genericPassword })
    }

    @Test func ignoresShortTokenValues() {
        let text = #"token = "abc""#
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .genericToken })
    }

    // MARK: - Comment Skipping

    @Test func skipsSecretsInLineComments() {
        let text = "// password = \"SuperSecret123\""
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .genericPassword })
    }

    @Test func skipsSecretsInHashComments() {
        let text = "# api_key = \"abcdef1234567890\""
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .genericAPIKey })
    }

    @Test func skipsSecretsInIndentedComments() {
        let text = "    // password = \"SuperSecret123\""
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .genericPassword })
    }

    @Test func doesNotSkipSecretsAfterNonCommentCode() {
        let text = "let x = 1; password = \"SuperSecret123\""
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    // MARK: - Empty / No Matches

    @Test func emptyTextReturnsNoMatches() {
        let matches = detector.detect(in: "")
        #expect(matches.isEmpty)
    }

    @Test func normalCodeReturnsNoMatches() {
        let text = """
        func calculateSum(_ a: Int, _ b: Int) -> Int {
            return a + b
        }
        """
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    @Test func containsSecretsReturnsFalseForNormalCode() {
        let text = "let x = 42"
        #expect(!detector.containsSecrets(in: text))
    }

    @Test func containsSecretsReturnsTrueForSecret() {
        let text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        #expect(detector.containsSecrets(in: text))
    }

    @Test func containsSecretsEmptyText() {
        #expect(!detector.containsSecrets(in: ""))
    }

    @Test func containsSecretsRespectsComments() {
        // containsSecrets must skip commented-out secrets, same as detect()
        let commented = "// password = \"SuperSecret123\""
        #expect(!detector.containsSecrets(in: commented))

        let blockCommented = "/* password = \"SuperSecret123\" */"
        #expect(!detector.containsSecrets(in: blockCommented))
    }

    // MARK: - Masking

    @Test func maskReplacesSecretWithBullets() {
        let text = "token = ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let masked = detector.mask(in: text)
        #expect(!masked.contains("ghp_"))
        #expect(masked.contains("\u{2022}"))
    }

    @Test func maskPreservesNonSecretText() {
        let text = "let x = 42"
        let masked = detector.mask(in: text)
        #expect(masked == text)
    }

    // MARK: - Multiple Secrets

    @Test func detectsMultipleSecretsInSameText() {
        let text = """
        GITHUB_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij
        AWS_KEY=AKIAIOSFODNN7EXAMPLE
        """
        let matches = detector.detect(in: text)
        let kinds = Set(matches.map(\.kind))
        #expect(kinds.contains(.githubToken))
        #expect(kinds.contains(.awsAccessKey))
    }

    // MARK: - Masking Multiple Secrets (Crash Regression)

    @Test func maskMultipleSecretsOnSameLine() {
        // Two secrets on the same line — must not crash from index invalidation
        let text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij AKIAIOSFODNN7EXAMPLE"
        let masked = detector.mask(in: text)
        #expect(!masked.contains("ghp_"))
        #expect(!masked.contains("AKIA"))
        #expect(masked.contains("\u{2022}"))
    }

    @Test func maskThreeSecretsPreservesStructure() {
        let text = """
        ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij
        AKIAIOSFODNN7EXAMPLE
        password = "SuperSecret123"
        """
        let masked = detector.mask(in: text)
        #expect(!masked.contains("ghp_"))
        #expect(!masked.contains("AKIA"))
        #expect(!masked.contains("SuperSecret123"))
        // Newlines must be preserved
        #expect(masked.contains("\n"))
    }

    @Test func maskMultipleSecretsOnSameLinePreservesSurroundingText() {
        let text = "key1=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij key2=AKIAIOSFODNN7EXAMPLE end"
        let masked = detector.mask(in: text)
        #expect(masked.hasPrefix("key1="))
        #expect(masked.hasSuffix("end"))
    }

    // MARK: - Block Comment Skipping

    @Test func skipsSecretsInBlockComments() {
        let text = """
        /* password = "SuperSecret123" */
        let x = 42
        """
        let matches = detector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .genericPassword })
    }

    @Test func skipsSecretsInMultilineBlockComments() {
        let text = """
        /*
         * AKIAIOSFODNN7EXAMPLE
         * ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij
         */
        """
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    @Test func doesNotSkipSecretsAfterClosedBlockComment() {
        let text = """
        /* comment */ password = "SuperSecret123"
        """
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    // MARK: - .env Format (No Quotes)

    @Test func detectsPasswordInEnvFormat() {
        let text = "PASSWORD=SuperSecretPassword123"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    @Test func detectsTokenInEnvFormat() {
        let text = "ACCESS_TOKEN=eyJhbGciOiJIUzI1NiJ9"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericToken })
    }

    @Test func detectsSecretInEnvFormat() {
        let text = "CLIENT_SECRET=abcdef1234567890"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericSecret })
    }

    @Test func detectsApiKeyInEnvFormat() {
        let text = "API_KEY=abcdef1234567890"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericAPIKey })
    }

    @Test func envFormatIgnoresCommentedLines() {
        let text = "# API_KEY=abcdef1234567890"
        let matches = detector.detect(in: text)
        #expect(matches.isEmpty)
    }

    // MARK: - SecretMatch Equatable

    @Test func secretMatchEquality() {
        let text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches1 = detector.detect(in: text)
        let matches2 = detector.detect(in: text)
        #expect(matches1 == matches2)
    }

    // MARK: - SecretKind Labels

    @Test func allKindsHaveLabels() {
        for kind in SecretKind.allCases {
            #expect(!kind.label.isEmpty, "\(kind.rawValue) should have a non-empty label")
        }
    }

    // MARK: - Custom Config

    @Test func customPatternDetectsMatches() {
        let config = PineSecretsConfig(
            customPatterns: [CustomSecretPattern(name: "MyToken", pattern: #"MYAPP_[A-Z]{10}"#)],
            disabledKinds: []
        )
        let customDetector = SecretDetector(config: config)
        let text = "key = MYAPP_ABCDEFGHIJ"
        let matches = customDetector.detect(in: text)
        #expect(!matches.isEmpty)
    }

    @Test func disabledKindsAreSkipped() {
        let config = PineSecretsConfig(
            customPatterns: [],
            disabledKinds: ["githubToken"]
        )
        let customDetector = SecretDetector(config: config)
        let text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches = customDetector.detect(in: text)
        #expect(matches.allSatisfy { $0.kind != .githubToken })
    }

    @Test func invalidCustomPatternIsSkipped() {
        let config = PineSecretsConfig(
            customPatterns: [CustomSecretPattern(name: "Bad", pattern: "[invalid")],
            disabledKinds: []
        )
        // Should not crash
        let customDetector = SecretDetector(config: config)
        let matches = customDetector.detect(in: "hello")
        #expect(matches.isEmpty)
    }

    // MARK: - Config Loading

    @Test func loadConfigReturnsNilForMissingFile() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = SecretDetector.loadConfig(from: tempDir)
        #expect(config == nil)
    }

    @Test func loadConfigParsesValidFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = PineSecretsConfig(
            customPatterns: [CustomSecretPattern(name: "Test", pattern: "TEST_[0-9]+")],
            disabledKinds: ["awsAccessKey"]
        )
        let data = try JSONEncoder().encode(config)
        try data.write(to: tempDir.appendingPathComponent(".pinesecrets"))

        let loaded = SecretDetector.loadConfig(from: tempDir)
        #expect(loaded == config)
    }

    // MARK: - PineSecretsConfig

    @Test func pineSecretsConfigDefaultInit() {
        let config = PineSecretsConfig()
        #expect(config.customPatterns.isEmpty)
        #expect(config.disabledKinds.isEmpty)
    }

    @Test func pineSecretsConfigCodable() throws {
        let config = PineSecretsConfig(
            customPatterns: [CustomSecretPattern(name: "A", pattern: "B")],
            disabledKinds: ["awsAccessKey"]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PineSecretsConfig.self, from: data)
        #expect(decoded == config)
    }

    // MARK: - Edge Cases

    @Test func singleCharacterTextDoesNotCrash() {
        let matches = detector.detect(in: "x")
        #expect(matches.isEmpty)
    }

    @Test func veryLongLineDoesNotCrash() {
        let longLine = String(repeating: "a", count: 10_000)
        let matches = detector.detect(in: longLine)
        #expect(matches.isEmpty)
    }

    @Test func multilineTextWithMixedSecrets() {
        let text = """
        # Config
        database_url = "postgres://localhost/mydb"
        password = "SuperSecretPassword123"
        token = ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij
        -----BEGIN RSA PRIVATE KEY-----
        some key content
        -----END RSA PRIVATE KEY-----
        """
        let matches = detector.detect(in: text)
        let kinds = Set(matches.map(\.kind))
        #expect(kinds.contains(.genericPassword))
        #expect(kinds.contains(.githubToken))
        #expect(kinds.contains(.genericPrivateKey))
    }

    @Test func secretOnFirstLineDetected() {
        let text = "password = \"SuperSecret123\""
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    @Test func unicodeTextDoesNotCrash() {
        let text = "password = \"\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\u{1F600}\""
        // Emoji password — should be detected as generic password if 8+ chars
        let matches = detector.detect(in: text)
        // May or may not match depending on character counting, but should not crash
        _ = matches
    }

    @Test func matchRangesAreValid() {
        let text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij is my token"
        let matches = detector.detect(in: text)
        for match in matches {
            #expect(match.range.lowerBound >= text.startIndex)
            #expect(match.range.upperBound <= text.endIndex)
            let value = String(text[match.range])
            #expect(!value.isEmpty)
        }
    }

    @Test func matchesAreSortedByPosition() {
        let text = """
        AKIAIOSFODNN7EXAMPLE
        ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij
        """
        let matches = detector.detect(in: text)
        for i in 1..<matches.count {
            #expect(matches[i].range.lowerBound >= matches[i - 1].range.lowerBound)
        }
    }

    // MARK: - Deduplication

    @Test func overlappingMatchesAreDeduplicatedToFirst() {
        // If a token matches multiple rules, only the first (higher priority) should remain
        let text = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
        let matches = detector.detect(in: text)
        // Should have exactly 1 match, not multiple overlapping
        #expect(matches.count == 1)
    }

    // MARK: - Case Insensitive Patterns

    @Test func passwordAssignmentCaseInsensitive() {
        let text = #"PASSWORD = "SuperSecret123""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }

    @Test func awsSecretKeyCaseInsensitive() {
        let text = #"AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY""#
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .awsSecretKey })
    }

    // MARK: - Single Quote Values

    @Test func detectsPasswordInSingleQuotes() {
        let text = "password = 'SuperSecret123'"
        let matches = detector.detect(in: text)
        #expect(matches.contains { $0.kind == .genericPassword })
    }
}
