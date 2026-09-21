//
//  SnapshotReferenceResolutionTests.swift
//  PineTests
//
//  Unit coverage for the per-OS reference filename resolution added in
//  #1620: `osSpecific: false` keeps the shared single reference, `true`
//  appends the running macOS major version, and the resolved URL stays a
//  sibling of the test sources under `__Snapshots__/`.
//

import Foundation
import Testing

struct SnapshotReferenceResolutionTests {

    // Expected suffix is derived from the same source the harness uses, so
    // the suite pins the *format and position* of the suffix rather than the
    // runner's OS version, and passes on both the macos-26 and xcode-27 lanes.
    private static let major = ProcessInfo.processInfo
        .operatingSystemVersion
        .majorVersion

    // MARK: - Filename construction

    @Test("shared references resolve to the name as-is")
    func sharedFilenameIsUnchanged() {
        #expect(
            SnapshotHarness.referenceFilename(
                for: "AgentInboxToolbarButton.zero.light",
                osSpecific: false
            ) == "AgentInboxToolbarButton.zero.light"
        )
    }

    @Test("os-specific references append the macOS major-version suffix")
    func osSpecificFilenameAppendsSuffix() {
        #expect(
            SnapshotHarness.referenceFilename(
                for: "AgentInboxToolbarButton.zero.light",
                osSpecific: true
            ) == "AgentInboxToolbarButton.zero.light.macos\(Self.major)"
        )
    }

    @Test("the suffix is major-version only")
    func suffixCarriesMajorVersionOnly() {
        #expect(SnapshotHarness.currentOSNameSuffix == "macos\(Self.major)")
        // Minor and patch must not leak into a reference filename: a 27.1
        // runner has to keep comparing against the macos27 baseline.
        #expect(!SnapshotHarness.currentOSNameSuffix.contains("."))
        #expect(SnapshotHarness.currentOSNameSuffix.hasPrefix("macos"))
    }

    @Test("an empty name still resolves without corrupting the filename")
    func emptyNameResolution() {
        #expect(
            SnapshotHarness.referenceFilename(for: "", osSpecific: false) == ""
        )
        #expect(
            SnapshotHarness.referenceFilename(for: "", osSpecific: true)
                == ".macos\(Self.major)"
        )
    }

    // MARK: - URL resolution

    @Test("resolved reference URL lives beside the test sources with the .png extension")
    func referenceURLLocation() throws {
        let url = SnapshotHarness.referenceURL(
            for: "AgentActivityView.populated.dark",
            testFile: #filePath,
            osSpecific: true
        )
        #expect(url.lastPathComponent == "AgentActivityView.populated.dark.macos\(Self.major).png")
        #expect(url.deletingLastPathComponent().lastPathComponent == "__Snapshots__")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent()
            == URL(fileURLWithPath: #filePath).deletingLastPathComponent())
    }

    @Test("shared and os-specific calls resolve to different files")
    func osSpecificChangesTheResolvedFile() {
        let shared = SnapshotHarness.referenceURL(
            for: "SomeView.dark",
            testFile: #filePath,
            osSpecific: false
        )
        let perOS = SnapshotHarness.referenceURL(
            for: "SomeView.dark",
            testFile: #filePath,
            osSpecific: true
        )
        #expect(shared.lastPathComponent == "SomeView.dark.png")
        #expect(perOS.lastPathComponent == "SomeView.dark.macos\(Self.major).png")
        #expect(shared != perOS)
    }
}
