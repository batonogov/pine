//
//  RecoveryUnsavedWorkTests.swift
//  PineTests
//
//  #1760: Save a Copy… in the recovery list. A snapshot is a whole unsaved
//  buffer the user has not decided about yet, so the copy must reach the
//  disk in one piece, never under the original's name or path, and never at
//  the cost of the snapshot itself — nothing collects it by age any more,
//  so a failed copy must not be the thing that loses the work.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Recovery Save a Copy")
@MainActor
struct RecoveryUnsavedWorkTests {

    // MARK: - The suggested file name

    @Test("The suggested name is the original with .recovered inserted")
    func suggestedNameInsertsRecoveredBeforeTheExtension() {
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/main.swift",
            content: "unsaved"
        )

        #expect(
            RecoveryManager.saveCopyFileName(for: entry)
                == "main.recovered.swift"
        )
    }

    @Test("A file without an extension gains .recovered instead")
    func suggestedNameAppendsRecoveredWithoutAnExtension() {
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/Makefile",
            content: "unsaved"
        )

        #expect(
            RecoveryManager.saveCopyFileName(for: entry) == "Makefile.recovered"
        )
    }

    @Test("An untitled buffer keeps its display name and a .txt extension")
    func suggestedNameForAnUntitledBuffer() {
        let entry = RecoveryEntry(
            originalPath: "",
            untitledName: "Untitled 2",
            content: "draft"
        )

        let name = RecoveryManager.saveCopyFileName(for: entry)
        #expect(name == "Untitled 2.recovered.txt")
    }

    @Test("No suggested name is ever the original file's own name")
    func suggestedNameIsNeverTheOriginalName() {
        // The panel opens in the file's own folder, so the original name
        // would make its default answer "replace the file I was editing".
        let entries = [
            RecoveryEntry(
                originalPath: "/tmp/project/report.pdf", content: "x"
            ),
            RecoveryEntry(originalPath: "/tmp/project/notes", content: "x"),
            RecoveryEntry(
                originalPath: "",
                untitledName: "Scratch",
                content: "x"
            ),
        ]

        for entry in entries {
            let suggested = RecoveryManager.saveCopyFileName(for: entry)
            let original = entry.originalPath.isEmpty
                ? ""
                : (entry.originalPath as NSString).lastPathComponent
            #expect(
                suggested != original,
                """
                "\(suggested)" is the original name; the panel's default \
                answer would overwrite the buffer the snapshot was taken \
                from
                """
            )
            #expect(suggested.contains(".recovered"))
        }
    }

    // MARK: - The starting folder

    @Test("The panel opens in the file's own folder while it exists")
    func startingFolderIsTheFileOwns() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let entry = RecoveryEntry(
            originalPath: dir.appendingPathComponent("main.swift").path,
            content: "unsaved"
        )

        // Compared as standardized paths: `deletingLastPathComponent` keeps
        // the trailing slash in the URL's own representation, which `==`
        // counts as a difference.
        #expect(
            RecoveryManager.saveCopyDirectory(for: entry)
                .standardizedFileURL.path == dir.standardizedFileURL.path
        )
    }

    @Test("A vanished folder falls back to Documents, not to a crash")
    func vanishedFolderFallsBackToDocuments() throws {
        let entry = RecoveryEntry(
            originalPath: "/tmp/pine-gone-\(UUID().uuidString)/main.swift",
            content: "unsaved"
        )
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        #expect(RecoveryManager.saveCopyDirectory(for: entry) == documents)
    }

    @Test("An untitled buffer starts in Documents")
    func untitledBufferStartsInDocuments() {
        let entry = RecoveryEntry(originalPath: "", content: "draft")
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]

        #expect(RecoveryManager.saveCopyDirectory(for: entry) == documents)
    }

    // MARK: - The copy itself

    @Test("A copy writes the buffer's content in its own encoding")
    func copyWritesTheContentInTheSnapshotEncoding() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let destination = dir.appendingPathComponent("copy.swift")
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/main.swift",
            content: "let recovered = „ÄÖÜ“",
            encoding: .utf8
        )

        try RecoveryManager.writeCopy(
            of: entry,
            to: destination,
            replacing: true
        )

        #expect(
            try String(contentsOf: destination, encoding: .utf8)
                == entry.content
        )
    }

    @Test("The original file is never the destination")
    func theOriginalFileIsRefusedAsDestination() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let original = dir.appendingPathComponent("main.swift")
        try "saved contents".write(to: original, atomically: true, encoding: .utf8)
        let entry = RecoveryEntry(originalPath: original.path, content: "dirty")

        #expect(throws: RecoveryCopyFailure.originalFile) {
            try RecoveryManager.writeCopy(
                of: entry,
                to: original,
                replacing: true
            )
        }
        // The refusal wrote nothing: the file on disk still says what it
        // said before the attempt.
        #expect(
            try String(contentsOf: original, encoding: .utf8)
                == "saved contents"
        )
    }

    @Test("The original is refused case-insensitively")
    func theOriginalIsRefusedRegardlessOfCase() throws {
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/main.swift",
            content: "dirty"
        )
        let destination = URL(
            fileURLWithPath: "/tmp/PROJECT/MAIN.SWIFT"
        )

        #expect(throws: RecoveryCopyFailure.originalFile) {
            try RecoveryManager.writeCopy(
                of: entry,
                to: destination,
                replacing: true
            )
        }
    }

    @Test("The original is refused across Unicode normalization forms")
    func theOriginalIsRefusedRegardlessOfNormalization() throws {
        // Finder writes decomposed names (NFD), IMEs and dead keys compose
        // them (NFC), and APFS treats the pair as one file — so the panel's
        // replace confirmation for the decomposed spelling really resolves
        // to the original file the snapshot was taken from.
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/caf\u{e9}.md",
            content: "dirty"
        )
        let destination = URL(
            fileURLWithPath: "/tmp/project/cafe\u{301}.md"
        )

        #expect(throws: RecoveryCopyFailure.originalFile) {
            try RecoveryManager.writeCopy(
                of: entry,
                to: destination,
                replacing: true
            )
        }
    }

    @Test("Text that cannot be encoded in the snapshot's encoding is refused")
    func unencodableTextIsRefusedBeforeAnythingIsWritten() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let destination = dir.appendingPathComponent("copy.txt")
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/main.swift",
            content: "emoji 🙂 does not survive ASCII",
            encoding: .ascii
        )

        #expect(throws: RecoveryCopyFailure.cannotEncode) {
            try RecoveryManager.writeCopy(
                of: entry,
                to: destination,
                replacing: true
            )
        }
        #expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "A refused copy left a partial file behind"
        )
    }

    @Test("Without the panel's blessing an existing file is never replaced")
    func anUnconfirmedDestinationIsNotOverwritten() throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let destination = dir.appendingPathComponent("existing.txt")
        try "earlier".write(to: destination, atomically: true, encoding: .utf8)
        let entry = RecoveryEntry(
            originalPath: "/tmp/project/other.swift",
            content: "newer"
        )

        // The refusal must be a thrown error, not the Foundation assertion
        // `Data.write(options: .withoutOverwriting)` traps with on this OS
        // (S3's crash forensics, 2026-11-26).
        #expect(throws: NSError.self) {
            try RecoveryManager.writeCopy(
                of: entry,
                to: destination,
                replacing: false
            )
        }
        #expect(
            try String(contentsOf: destination, encoding: .utf8) == "earlier"
        )
    }

    @Test("A discard the filesystem refuses is reported, not claimed")
    func refusedDiscardIsReportedBack() throws {
        // Discard is irreversible only when the unlink succeeds. An
        // EACCES/EIO on the directory leaves the snapshot on disk, and the
        // manager has to say so instead of letting the sheet report a
        // destruction that never happened.
        let dir = try makeTempDir()
        defer {
            // Give the directory its write bit back so cleanup can run.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dir.path
            )
            removeTempDir(dir)
        }
        let id = UUID()
        let file = dir.appendingPathComponent("\(id.uuidString).json")
        try Data("{}".utf8).write(to: file)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: dir.path
        )

        let manager = RecoveryManager(recoveryDirectory: dir)
        let failed = manager.deleteSnapshots(withRecoveryIDs: [id])

        #expect(
            failed == Set([id]),
            "an unlink failure was reported as a completed discard"
        )
        #expect(
            FileManager.default.fileExists(atPath: file.path),
            "the snapshot disappeared even though the unlink was refused"
        )
    }

    // MARK: - The refusal sentences

    @Test("Each refusal has its own sentence, and a plain error a generic one")
    func refusalReasonsMapToTheirOwnSentences() {
        let fileName = "main.recovered.swift"

        let original = RecoveryDialogView.saveCopyFailure(
            RecoveryCopyFailure.originalFile,
            fileName: fileName
        )
        #expect(original.contains(fileName))
        #expect(
            original != RecoveryDialogView.saveCopyFailure(
                RecoveryCopyFailure.cannotEncode,
                fileName: fileName
            ),
            """
            The two refusals read the same; a user refused because the copy \
            would overwrite their file is told something else is wrong
            """
        )

        let encoding = RecoveryDialogView.saveCopyFailure(
            RecoveryCopyFailure.cannotEncode,
            fileName: fileName
        )
        #expect(encoding.contains(fileName))

        let reason = "the volume is read-only"
        let writeFailure = RecoveryDialogView.saveCopyFailure(
            NSError(
                domain: "PineTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            ),
            fileName: fileName
        )
        #expect(writeFailure.contains(fileName))
        #expect(writeFailure.contains(reason))
    }
}

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PineRecoverySaveCopyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
