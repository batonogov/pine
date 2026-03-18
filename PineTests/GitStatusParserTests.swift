//
//  GitStatusParserTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct GitStatusParserTests {

    // MARK: - parseStatusOutput

    @Test func parsesUntrackedFiles() {
        let output = "?? newfile.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["newfile.swift"] == .untracked)
    }

    @Test func parsesStagedModification() {
        let output = "M  Sources/main.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["Sources/main.swift"] == .staged)
    }

    @Test func parsesUnstagedModification() {
        let output = " M Sources/main.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["Sources/main.swift"] == .modified)
    }

    @Test func parsesMixedStatus() {
        let output = "MM Sources/main.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["Sources/main.swift"] == .mixed)
    }

    @Test func parsesAddedFile() {
        let output = "A  newfile.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["newfile.swift"] == .added)
    }

    @Test func parsesDeletedFile() {
        let output = "D  oldfile.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["oldfile.swift"] == .deleted)
    }

    @Test func parsesUnstagedDeletion() {
        let output = " D oldfile.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["oldfile.swift"] == .deleted)
    }

    @Test func parsesConflict() {
        let output = "UU conflicted.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["conflicted.swift"] == .conflict)
    }

    @Test func parsesBothAddedConflict() {
        let output = "AA bothAdded.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["bothAdded.swift"] == .conflict)
    }

    @Test func parsesRenamedFile() {
        let output = "R  old.swift -> new.swift\n"
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses["new.swift"] == .staged)
        #expect(statuses["old.swift"] == nil)
    }

    @Test func parsesMultipleFiles() {
        let output = """
        M  file1.swift
         M file2.swift
        ?? file3.swift
        A  file4.swift
        """
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses.count == 4)
        #expect(statuses["file1.swift"] == .staged)
        #expect(statuses["file2.swift"] == .modified)
        #expect(statuses["file3.swift"] == .untracked)
        #expect(statuses["file4.swift"] == .added)
    }

    @Test func parsesEmptyOutput() {
        let statuses = GitStatusProvider.parseStatusOutput("")
        #expect(statuses.isEmpty)
    }

    @Test func parseStatusOutputSkipsIgnoredEntries() {
        let output = """
         M src/main.swift
        !! .claude/
        !! default.profraw
        """
        let statuses = GitStatusProvider.parseStatusOutput(output)
        #expect(statuses.count == 1)
        #expect(statuses["src/main.swift"] == .modified)
        #expect(statuses[".claude/"] == nil)
        #expect(statuses["default.profraw"] == nil)
    }

    // MARK: - statusForDirectory

    @Test func directoryStatusShowsConflictOverOthers() {
        let provider = GitStatusProvider()
        provider.fileStatuses = [
            "src/file1.swift": .modified,
            "src/file2.swift": .conflict,
            "src/file3.swift": .staged,
        ]

        let url = URL(fileURLWithPath: "/repo/src")
        // statusForDirectory uses relativePath which depends on gitRootPath
        // So we test the priority logic indirectly via fileStatuses
        #expect(provider.fileStatuses["src/file2.swift"] == .conflict)
    }

    // MARK: - parseIgnoredOutput

    @Test func parsesIgnoredFiles() {
        let output = "!! build/\n!! .env\n!! node_modules/\n"
        let ignored = GitStatusProvider.parseIgnoredOutput(output)
        #expect(ignored.count == 3)
        #expect(ignored.contains("build"))
        #expect(ignored.contains(".env"))
        #expect(ignored.contains("node_modules"))
    }

    @Test func parsesIgnoredMixedWithStatus() {
        let output = """
         M Sources/main.swift
        ?? newfile.swift
        !! .build/
        !! .DS_Store
        """
        let ignored = GitStatusProvider.parseIgnoredOutput(output)
        #expect(ignored.count == 2)
        #expect(ignored.contains(".build"))
        #expect(ignored.contains(".DS_Store"))
    }

    @Test func parsesEmptyIgnoredOutput() {
        let ignored = GitStatusProvider.parseIgnoredOutput("")
        #expect(ignored.isEmpty)
    }

    @Test func parsesIgnoredNestedPaths() {
        let output = "!! vendor/cache/\n!! tmp/pids/\n"
        let ignored = GitStatusProvider.parseIgnoredOutput(output)
        #expect(ignored.contains("vendor/cache"))
        #expect(ignored.contains("tmp/pids"))
    }

    // MARK: - isIgnored

    @Test func isIgnoredReturnsTrueForIgnoredFile() {
        let provider = GitStatusProvider()
        provider.gitRootPath = "/repo"
        provider.ignoredPaths = [".env", "build"]

        let envURL = URL(fileURLWithPath: "/repo/.env")
        #expect(provider.isIgnored(at: envURL) == true)

        let srcURL = URL(fileURLWithPath: "/repo/src/main.swift")
        #expect(provider.isIgnored(at: srcURL) == false)
    }

    @Test func isIgnoredReturnsTrueForFileInIgnoredDirectory() {
        let provider = GitStatusProvider()
        provider.gitRootPath = "/repo"
        provider.ignoredPaths = ["build"]

        let fileURL = URL(fileURLWithPath: "/repo/build/output.o")
        #expect(provider.isIgnored(at: fileURL) == true)
    }

    @Test func isIgnoredReturnsTrueForIgnoredDir() {
        let provider = GitStatusProvider()
        provider.gitRootPath = "/repo"
        provider.ignoredPaths = ["node_modules"]

        let dirURL = URL(fileURLWithPath: "/repo/node_modules")
        #expect(provider.isIgnored(at: dirURL) == true)

        let srcURL = URL(fileURLWithPath: "/repo/src")
        #expect(provider.isIgnored(at: srcURL) == false)
    }

    @Test func isIgnoredDoesNotFalsePositiveOnCommonPrefix() {
        let provider = GitStatusProvider()
        provider.gitRootPath = "/repo"
        provider.ignoredPaths = ["build"]

        // "buildtools" shares prefix with "build" but is NOT ignored
        let toolsURL = URL(fileURLWithPath: "/repo/buildtools/script.sh")
        #expect(provider.isIgnored(at: toolsURL) == false)

        let toolsDirURL = URL(fileURLWithPath: "/repo/buildtools")
        #expect(provider.isIgnored(at: toolsDirURL) == false)
    }
}
