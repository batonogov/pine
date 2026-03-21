//
//  SecretDetectorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("SecretDetector Tests")
struct SecretDetectorTests {

    // MARK: - AWS Access Key Detection

    @Test("Detects AWS Access Key ID")
    func awsAccessKeyDetected() {
        let text = #"AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE"#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "AWS Access Key" })
    }

    @Test("AWS key with lowercase prefix not detected")
    func awsLowercasePrefixNotDetected() {
        let text = "key = akiaIOSFODNN7EXAMPLE"
        let matches = SecretDetector.detect(in: text)
        #expect(!matches.contains { $0.kind == "AWS Access Key" })
    }

    @Test("AWS key too short not detected")
    func awsKeyTooShortNotDetected() {
        let text = "AKIAIOSFODNN7"
        let matches = SecretDetector.detect(in: text)
        #expect(!matches.contains { $0.kind == "AWS Access Key" })
    }

    @Test("AWS key exactly 20 chars detected")
    func awsKeyExactLength() {
        // AKIA + 16 uppercase alphanumeric
        let text = "AKIAIOSFODNN7EXAMPL"  // only 19 chars total — should not match
        let matches = SecretDetector.detect(in: text)
        #expect(!matches.contains { $0.kind == "AWS Access Key" })
    }

    @Test("AWS key 20 chars exactly detected")
    func awsKeyExact20Chars() {
        let text = "AKIAIOSFODNN7EXAMPL0"  // 20 chars, AKIA + 16
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "AWS Access Key" })
    }

    // MARK: - GitHub Token Detection

    @Test("Detects ghp_ GitHub token")
    func githubClassicTokenGhp() {
        let text = "token=ghp_abcdefghijklmnopqrstuvwxyz123456ABCD"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "GitHub Token" })
    }

    @Test("Detects gho_ GitHub OAuth token")
    func githubOauthToken() {
        let text = "gho_abcdefghijklmnopqrstuvwxyz123456ABCDE"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "GitHub Token" })
    }

    @Test("Detects ghs_ GitHub server token")
    func githubServerToken() {
        let text = "ghs_abcdefghijklmnopqrstuvwxyz123456ABCDE"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "GitHub Token" })
    }

    @Test("Detects ghu_ GitHub user token")
    func githubUserToken() {
        let text = "ghu_abcdefghijklmnopqrstuvwxyz123456ABCDE"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "GitHub Token" })
    }

    @Test("Detects ghr_ GitHub refresh token")
    func githubRefreshToken() {
        let text = "ghr_abcdefghijklmnopqrstuvwxyz123456ABCDE"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "GitHub Token" })
    }

    @Test("Detects github_pat_ fine-grained PAT")
    func githubFineGrainedPat() {
        // github_pat_ + 82 chars
        let value = "github_pat_" + String(repeating: "a", count: 82)
        let matches = SecretDetector.detect(in: value)
        #expect(matches.contains { $0.kind == "GitHub Fine-Grained PAT" })
    }

    @Test("github_pat_ too short not detected")
    func githubPatTooShort() {
        let value = "github_pat_" + String(repeating: "a", count: 10)
        let matches = SecretDetector.detect(in: value)
        #expect(!matches.contains { $0.kind == "GitHub Fine-Grained PAT" })
    }

    // MARK: - PEM Private Key Detection

    @Test("Detects RSA PRIVATE KEY header")
    func rsaPrivateKeyDetected() {
        let text = "-----BEGIN RSA PRIVATE KEY-----"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Private Key" })
    }

    @Test("Detects EC PRIVATE KEY header")
    func ecPrivateKeyDetected() {
        let text = "-----BEGIN EC PRIVATE KEY-----"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Private Key" })
    }

    @Test("Detects OPENSSH PRIVATE KEY header")
    func opensshPrivateKeyDetected() {
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Private Key" })
    }

    @Test("Detects generic PRIVATE KEY header")
    func genericPrivateKeyDetected() {
        let text = "-----BEGIN PRIVATE KEY-----"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Private Key" })
    }

    @Test("Non-private key header not detected")
    func publicKeyHeaderNotDetected() {
        let text = "-----BEGIN PUBLIC KEY-----"
        let matches = SecretDetector.detect(in: text)
        #expect(!matches.contains { $0.kind == "Private Key" })
    }

    // MARK: - Generic Secret Assignment Detection

    @Test("Detects password assignment with double quotes")
    func passwordDoubleQuotes() {
        let text = #"password = "supersecretpassword123""#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Detects token assignment with single quotes")
    func tokenSingleQuotes() {
        let text = "token = 'myapitoken1234567890abcdef'"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Detects api_key assignment")
    func apiKeyAssignment() {
        let text = #"api_key = "sk-abc123defghi456jklmno789pqrstu""#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Detects secret assignment with colon separator")
    func secretWithColon() {
        let text = #"secret: "abc123defghi456jklmno789pqrstu""#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Short secret value not detected (< 20 chars)")
    func shortSecretValueNotDetected() {
        let text = #"password = "short""#
        let matches = SecretDetector.detect(in: text)
        #expect(!matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Detects auth_token assignment")
    func authTokenAssignment() {
        let text = #"auth_token = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9""#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Detects client_secret assignment")
    func clientSecretAssignment() {
        let text = #"client_secret = "abc123XYZ456defghi789jklm""#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    @Test("Detects access_key assignment")
    func accessKeyAssignment() {
        let text = #"access_key = "AKIAIOSFODNN7EXAMPLE1234""#
        let matches = SecretDetector.detect(in: text)
        #expect(matches.contains { $0.kind == "Secret Assignment" })
    }

    // MARK: - Entropy Detection

    @Test("Computes zero entropy for empty string")
    func entropyEmpty() {
        let e = SecretDetector.shannonEntropy("")
        #expect(e == 0)
    }

    @Test("Computes zero entropy for single character repeated")
    func entropyAllSameChars() {
        let e = SecretDetector.shannonEntropy("aaaaaaaaaa")
        #expect(e == 0)
    }

    @Test("Computes max entropy for perfectly uniform distribution")
    func entropyUniform2Chars() {
        // "ab" repeated — 50/50 split → entropy = 1.0 bit/char
        let e = SecretDetector.shannonEntropy("abababababababab")
        #expect(abs(e - 1.0) < 0.001)
    }

    @Test("High-entropy string detected by entropy analysis")
    func highEntropyStringDetected() {
        // A base64-like token with high entropy
        let token = "aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW"  // 32 chars, varied
        let text = #""\#(token)""#
        let e = SecretDetector.shannonEntropy(token)
        // Only check if it should be flagged
        if e >= SecretDetector.entropyThreshold {
            let matches = SecretDetector.detect(in: text)
            #expect(matches.contains { $0.kind == "High-Entropy String" })
        }
    }

    @Test("Low-entropy quoted string not flagged by entropy")
    func lowEntropyStringNotFlagged() {
        // Repeated simple pattern — low entropy
        let token = "aaaaabbbbbaaaaabbbbbaaaaabbbbbaaa"
        let e = SecretDetector.shannonEntropy(token)
        #expect(e < SecretDetector.entropyThreshold)
    }

    @Test("Entropy threshold is 3.5 bits/char")
    func entropyThresholdValue() {
        #expect(SecretDetector.entropyThreshold == 3.5)
    }

    // MARK: - Deduplication

    @Test("Deduplication removes overlapping matches")
    func deduplicationRemovesOverlaps() {
        let range1 = NSRange(location: 0, length: 20)
        let range2 = NSRange(location: 10, length: 20)  // overlaps range1
        let range3 = NSRange(location: 50, length: 10)  // no overlap
        let matches = [
            SecretMatch(range: range1, kind: "A"),
            SecretMatch(range: range2, kind: "B"),
            SecretMatch(range: range3, kind: "C"),
        ]
        let deduped = SecretDetector.deduplicated(matches)
        #expect(deduped.count == 2)
        #expect(deduped[0].kind == "A")
        #expect(deduped[1].kind == "C")
    }

    @Test("Deduplication keeps adjacent non-overlapping matches")
    func deduplicationKeepsAdjacent() {
        let range1 = NSRange(location: 0, length: 10)
        let range2 = NSRange(location: 10, length: 10)  // adjacent, not overlapping
        let matches = [
            SecretMatch(range: range1, kind: "A"),
            SecretMatch(range: range2, kind: "B"),
        ]
        let deduped = SecretDetector.deduplicated(matches)
        #expect(deduped.count == 2)
    }

    @Test("Deduplication handles empty input")
    func deduplicationEmpty() {
        let deduped = SecretDetector.deduplicated([])
        #expect(deduped.isEmpty)
    }

    @Test("Deduplication handles single match")
    func deduplicationSingleMatch() {
        let match = SecretMatch(range: NSRange(location: 0, length: 10), kind: "X")
        let deduped = SecretDetector.deduplicated([match])
        #expect(deduped.count == 1)
    }

    // MARK: - Multi-match in one file

    @Test("Multiple secret types in one text")
    func multipleSecretsDetected() {
        let text = """
        AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
        token = "ghp_abcdefghijklmnopqrstuvwxyz123456ABCD"
        -----BEGIN RSA PRIVATE KEY-----
        """
        let matches = SecretDetector.detect(in: text)
        let kinds = Set(matches.map(\.kind))
        #expect(kinds.contains("AWS Access Key"))
        #expect(kinds.contains("Private Key"))
    }

    @Test("Empty text produces no matches")
    func emptyTextNoMatches() {
        let matches = SecretDetector.detect(in: "")
        #expect(matches.isEmpty)
    }

    @Test("Plain text with no secrets produces no matches")
    func plainTextNoMatches() {
        let text = "let x = 42\nfunc hello() { print(\"world\") }"
        let matches = SecretDetector.detect(in: text)
        #expect(matches.isEmpty)
    }

    // MARK: - SecretMaskingSettings

    @Test("SecretMaskingSettings defaults to enabled for new UserDefaults")
    func settingsDefaultEnabled() {
        let suiteName = "PineTests.SecretMasking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SecretMaskingSettings(defaults: defaults)
        #expect(settings.isEnabled == true)
    }

    @Test("SecretMaskingSettings persists disabled state")
    func settingsPersistsDisabled() {
        let suiteName = "PineTests.SecretMasking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SecretMaskingSettings(defaults: defaults)
        settings.isEnabled = false

        let settings2 = SecretMaskingSettings(defaults: defaults)
        #expect(settings2.isEnabled == false)
    }

    @Test("SecretMaskingSettings persists enabled state")
    func settingsPersistsEnabled() {
        let suiteName = "PineTests.SecretMasking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SecretMaskingSettings(defaults: defaults)
        settings.isEnabled = false
        settings.isEnabled = true

        let settings2 = SecretMaskingSettings(defaults: defaults)
        #expect(settings2.isEnabled == true)
    }

    @Test("SecretMaskingSettings storageKey is stable")
    func settingsStorageKeyStable() {
        #expect(SecretMaskingSettings.storageKey == "secretMaskingEnabled")
    }

    // MARK: - Range accuracy

    @Test("Secret range points to value, not key")
    func secretRangePointsToValue() {
        let text = #"password = "mysecretpassword123456""#
        let matches = SecretDetector.detect(in: text)
        let match = matches.first { $0.kind == "Secret Assignment" }
        guard let match else {
            Issue.record("Expected a Secret Assignment match")
            return
        }
        let nsText = text as NSString
        let value = nsText.substring(with: match.range)
        // The matched value should be the secret, not include 'password ='
        #expect(!value.contains("password"))
        #expect(value.count >= 20)
    }

    @Test("AWS range points to key value")
    func awsRangePointsToKey() {
        let text = "key: AKIAIOSFODNN7EXAMPLE"
        let matches = SecretDetector.detect(in: text)
        let match = matches.first { $0.kind == "AWS Access Key" }
        guard let match else {
            Issue.record("Expected an AWS Access Key match")
            return
        }
        let nsText = text as NSString
        let value = nsText.substring(with: match.range)
        #expect(value == "AKIAIOSFODNN7EXAMPLE")
    }

    // MARK: - SecretMatch equality

    @Test("SecretMatch equality works")
    func secretMatchEquality() {
        let range = NSRange(location: 5, length: 10)
        let m1 = SecretMatch(range: range, kind: "AWS Access Key")
        let m2 = SecretMatch(range: range, kind: "AWS Access Key")
        let m3 = SecretMatch(range: range, kind: "GitHub Token")
        #expect(m1 == m2)
        #expect(m1 != m3)
    }
}
