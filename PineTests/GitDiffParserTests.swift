//
//  GitDiffParserTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

struct GitDiffParserTests {

    // MARK: - parseHunkNewStart

    @Test func parsesSimpleHunkHeader() {
        let result = GitStatusProvider.parseHunkNewStart("@@ -1,3 +5,4 @@ func foo()")
        #expect(result == 5)
    }

    @Test func parsesHunkHeaderWithoutCount() {
        let result = GitStatusProvider.parseHunkNewStart("@@ -1 +10 @@")
        #expect(result == 10)
    }

    @Test func parsesHunkHeaderLineOne() {
        let result = GitStatusProvider.parseHunkNewStart("@@ -0,0 +1,5 @@")
        #expect(result == 1)
    }

    @Test func returnsNilForInvalidHeader() {
        #expect(GitStatusProvider.parseHunkNewStart("not a hunk header") == nil)
    }

    @Test func returnsNilForMissingPlus() {
        #expect(GitStatusProvider.parseHunkNewStart("@@ -1,3 @@") == nil)
    }

    // MARK: - parseDiff

    @Test func parsesAddedLines() {
        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """
        let result = GitStatusProvider.parseDiff(diff)
        #expect(result.count == 3)
        #expect(result[0] == GitLineDiff(line: 1, kind: .added))
        #expect(result[1] == GitLineDiff(line: 2, kind: .added))
        #expect(result[2] == GitLineDiff(line: 3, kind: .added))
    }

    @Test func parsesDeletedLines() {

        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -1,2 +1,0 @@
        -old line 1
        -old line 2
        """
        let result = GitStatusProvider.parseDiff(diff)
        #expect(result.count == 1)
        #expect(result[0] == GitLineDiff(line: 1, kind: .deleted))
    }

    @Test func parsesModifiedLines() {

        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -5,2 +5,2 @@
        -old line
        +new line
        """
        let result = GitStatusProvider.parseDiff(diff)
        #expect(result.count == 1)
        #expect(result[0] == GitLineDiff(line: 5, kind: .modified))
    }

    @Test func parsesMixedAdditionsAndModifications() {

        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -10,1 +10,3 @@
        -old
        +modified
        +added1
        +added2
        """
        let result = GitStatusProvider.parseDiff(diff)
        #expect(result.count == 3)
        #expect(result[0] == GitLineDiff(line: 10, kind: .modified))
        #expect(result[1] == GitLineDiff(line: 11, kind: .added))
        #expect(result[2] == GitLineDiff(line: 12, kind: .added))
    }

    @Test func parsesMultipleHunks() {

        let diff = """
        diff --git a/file.swift b/file.swift
        @@ -1,1 +1,1 @@
        -old1
        +new1
        @@ -20,0 +20,2 @@
        +added1
        +added2
        """
        let result = GitStatusProvider.parseDiff(diff)
        #expect(result.count == 3)
        #expect(result[0] == GitLineDiff(line: 1, kind: .modified))
        #expect(result[1] == GitLineDiff(line: 20, kind: .added))
        #expect(result[2] == GitLineDiff(line: 21, kind: .added))
    }

    @Test func parsesEmptyDiff() {

        let result = GitStatusProvider.parseDiff("")
        #expect(result.isEmpty)
    }
}
