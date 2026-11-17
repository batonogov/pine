import Foundation
import Testing
@testable import Pine

struct ClaudeCodeStreamVersionTests {
    @Test func parsesAndComparesVersions() throws {
        let v1 = try ClaudeCodeCLIVersion("2.1.311")
        let v2 = try ClaudeCodeCLIVersion("2.1.268")
        let v3 = try ClaudeCodeCLIVersion("2.2.0")
        #expect(v2 < v1)
        #expect(v1 < v3)
        #expect(v1 == try ClaudeCodeCLIVersion(2, 1, 311))
        #expect(v1.description == "2.1.311")
        for invalid in ["2.1", "2.1.311.4", "2.a.1", "2..1", "2.1.01x", "", "0x1.2.3", "2.1.-3"] {
            #expect(throws: ClaudeCodeStreamError.invalidVersion) {
                _ = try ClaudeCodeCLIVersion(invalid)
            }
        }
    }

    @Test func featureFloorsArePinnedPerCapability() throws {
        #expect(try ClaudeCodeStreamFeature.pendingPermissionRequests.minimumVersion ==
            ClaudeCodeCLIVersion(2, 1, 268))
        #expect(try ClaudeCodeStreamFeature.interruptReceipt.minimumVersion ==
            ClaudeCodeCLIVersion(2, 1, 205))
        #expect(try ClaudeCodeStreamFeature.interruptCancelQueued.minimumVersion ==
            ClaudeCodeCLIVersion(2, 1, 219))
        #expect(try ClaudeCodeStreamFeature.systemPromptSnapshotOff.minimumVersion ==
            ClaudeCodeCLIVersion(2, 1, 257))
        #expect(try ClaudeCodeStreamFeature.permissionPrompts.minimumVersion ==
            ClaudeCodeCLIVersion(2, 1, 259))
        #expect(try ClaudeCodeStreamFeature.claudeCodeVersionField.minimumVersion ==
            ClaudeCodeCLIVersion(2, 1, 296))
    }

    @Test func structuredSliceMinimumCoversRecoveryAndCancellation() throws {
        #expect(try ClaudeCodeStreamPins.structuredSliceMinimum == ClaudeCodeCLIVersion(2, 1, 296))
        #expect(try ClaudeCodeStreamPins.verified == ClaudeCodeCLIVersion(2, 1, 311))
        #expect(ClaudeCodeStreamPins.supportsStructuredSlice(try ClaudeCodeCLIVersion(2, 1, 296)))
        #expect(!ClaudeCodeStreamPins.supportsStructuredSlice(try ClaudeCodeCLIVersion(2, 1, 295)))
        #expect(ClaudeCodeStreamPins.supportsStructuredSlice(try ClaudeCodeCLIVersion(2, 1, 311)))
        #expect(!ClaudeCodeStreamPins.supportsStructuredSlice(try ClaudeCodeCLIVersion(3, 0, 0)))
    }

    @Test func capabilityAdvertenceBeatsVersionFloor() {
        // Observed array present: membership decides, version is irrelevant.
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .interruptReceipt, reportedVersion: "2.1.204",
            observedCapabilities: ["interrupt_receipt_v1"]
        ) == .available)
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .interruptReceipt, reportedVersion: "2.1.311",
            observedCapabilities: ["ui_surface_v1"]
        ) == .unavailable)
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .interruptCancelQueued, reportedVersion: "2.1.311",
            observedCapabilities: ["interrupt_receipt_v1"]
        ) == .unavailable)
    }

    @Test func versionFloorAppliesWithoutCapabilityArray() {
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .pendingPermissionRequests, reportedVersion: "2.1.268", observedCapabilities: nil
        ) == .available)
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .pendingPermissionRequests, reportedVersion: "2.1.267", observedCapabilities: nil
        ) == .unavailable)
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .claudeCodeVersionField, reportedVersion: "2.1.205", observedCapabilities: nil
        ) == .unavailable)
    }

    @Test func missingEvidenceIsUnknownNotUnavailable() {
        // No capabilities array and no parseable version: the feature state
        // stays unknown. A missing pending_permission_requests field means an
        // older CLI, not "no pending requests".
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .pendingPermissionRequests, reportedVersion: nil, observedCapabilities: nil
        ) == .unknown)
        #expect(ClaudeCodeStreamFeatureDetection.availability(
            of: .pendingPermissionRequests, reportedVersion: "not-a-version", observedCapabilities: nil
        ) == .unknown)
    }

    @Test func accountObservationIsSeparateFromTransportAuth() throws {
        let none = ClaudeCodeStreamAccountState.observe(.object([
            "tokenSource": .string("none"), "apiProvider": .string("firstParty")
        ]))
        #expect(none == ClaudeCodeStreamAccountState(tokenSource: .none, provider: .firstParty))
        let oauth = ClaudeCodeStreamAccountState.observe(.object([
            "tokenSource": .string("oauth_token"), "apiProvider": .string("firstParty")
        ]))
        #expect(oauth?.tokenSource == .oauth)
        let bedrock = ClaudeCodeStreamAccountState.observe(.object([
            "tokenSource": .string("api_key"), "apiProvider": .string("bedrock")
        ]))
        #expect(bedrock?.provider == .bedrock)
        let future = ClaudeCodeStreamAccountState.observe(.object([
            "tokenSource": .string("some_future_source"), "apiProvider": .string("firstParty")
        ]))
        #expect(future?.tokenSource == .unknown("some_future_source"))
        // Absent or unparseable account data is an observation gap, not "no
        // credentials".
        #expect(ClaudeCodeStreamAccountState.observe(nil) == nil)
        #expect(ClaudeCodeStreamAccountState.observe(.object(["tokenSource": .string("none")])) == nil)
        #expect(ClaudeCodeStreamAccountState.observe(.object([
            "tokenSource": .number("1"), "apiProvider": .string("firstParty")
        ])) == nil)
        #expect(ClaudeCodeStreamAccountState.observe(.object([
            "tokenSource": .string("n" + String(repeating: "o", count: 128)), "apiProvider": .string("x")
        ])) == nil)
    }
}
