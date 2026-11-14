import Foundation
import Testing
@testable import Pine

struct CodexAppServerAccountStateTests {
    @Test func credentialsAreDistinctFromOwnedTransport() throws {
        #expect(try CodexAppServerAccountState(response: .object([
            "requiresOpenaiAuth": .bool(true), "account": .null
        ])) == .signInRequired)
        #expect(try CodexAppServerAccountState(response: .object([
            "requiresOpenaiAuth": .bool(false), "account": .null
        ])) == .externalProviderUnverified)
        #expect(try CodexAppServerAccountState(response: .object([
            "requiresOpenaiAuth": .bool(true),
            "account": .object(["type": .string("chatgpt"), "email": .string("SECRET-ACCOUNT-FIXTURE")])
        ])) == .credentialsConfigured)
    }

    @Test func futureAccountTypeDoesNotInventAuthentication() throws {
        #expect(try CodexAppServerAccountState(response: .object([
            "requiresOpenaiAuth": .bool(true), "account": .object(["type": .string("future")])
        ])) == .unknown)
        #expect(throws: CodexAppServerWireError.invalidEnvelope) {
            try CodexAppServerAccountState(response: .object(["account": .null]))
        }
    }
}
