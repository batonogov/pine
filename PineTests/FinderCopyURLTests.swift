//
//  FinderCopyURLTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("FileNameGenerator Tests")
struct FileNameGeneratorTests {

    private let baseURL = URL(fileURLWithPath: "/tmp/test/file.swift")
    private let noExtURL = URL(fileURLWithPath: "/tmp/test/Makefile")
    private let parentURL = URL(fileURLWithPath: "/tmp/test/")

    // MARK: - finderCopyURL

    @Test("Returns 'file copy.ext' when no copies exist")
    func firstCopy() {
        let result = FileNameGenerator.finderCopyURL(for: baseURL, fileExists: { _ in false })

        #expect(result?.lastPathComponent == "file copy.swift")
    }

    @Test("Skips existing copies and increments counter")
    func skipsExistingCopies() {
        let existing: Set<String> = [
            "/tmp/test/file copy.swift",
            "/tmp/test/file copy 2.swift"
        ]
        let result = FileNameGenerator.finderCopyURL(for: baseURL) { existing.contains($0) }

        #expect(result?.lastPathComponent == "file copy 3.swift")
    }

    @Test("Returns nil when all names are taken (graceful fallback)")
    func returnsNilWhenExhausted() {
        let result = FileNameGenerator.finderCopyURL(for: baseURL, fileExists: { _ in true })

        #expect(result == nil)
    }

    @Test("Handles files without extension")
    func noExtension() {
        let result = FileNameGenerator.finderCopyURL(for: noExtURL, fileExists: { _ in false })

        #expect(result?.lastPathComponent == "Makefile copy")
    }

    @Test("Tries exactly maxAttempts candidates before returning nil")
    func exactAttemptCount() {
        var callCount = 0
        let result = FileNameGenerator.finderCopyURL(for: baseURL) { _ in
            callCount += 1
            return true
        }

        #expect(result == nil)
        #expect(callCount == FileNameGenerator.maxAttempts)
    }

    // MARK: - uniqueName

    @Test("Returns base name when it does not exist")
    func uniqueNameBaseFree() {
        let result = FileNameGenerator.uniqueName("untitled", in: parentURL, fileExists: { _ in false })

        #expect(result == "untitled")
    }

    @Test("Appends counter when base name is taken")
    func uniqueNameIncrementsCounter() {
        let existing: Set<String> = [
            "/tmp/test/untitled",
            "/tmp/test/untitled 2"
        ]
        let result = FileNameGenerator.uniqueName("untitled", in: parentURL) { existing.contains($0) }

        #expect(result == "untitled 3")
    }

    @Test("Returns fallback name when all names are taken")
    func uniqueNameFallbackWhenExhausted() {
        let result = FileNameGenerator.uniqueName("untitled", in: parentURL, fileExists: { _ in true })

        #expect(result == "untitled \(FileNameGenerator.maxAttempts)")
    }

    @Test("uniqueName tries bounded number of candidates")
    func uniqueNameBoundedAttempts() {
        var callCount = 0
        _ = FileNameGenerator.uniqueName("test", in: parentURL) { _ in
            callCount += 1
            return true
        }

        // 1 for baseName check + (maxAttempts - 1) for counter 2...maxAttempts
        #expect(callCount == FileNameGenerator.maxAttempts)
    }
}
