//
//  FinderCopyURLTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Finder Copy URL Tests")
struct FinderCopyURLTests {

    private let baseURL = URL(fileURLWithPath: "/tmp/test/file.swift")
    private let noExtURL = URL(fileURLWithPath: "/tmp/test/Makefile")

    // MARK: - TabManager.finderCopyURL

    @Test("TabManager: returns 'file copy.ext' when no copies exist")
    func tabManagerFirstCopy() {
        let manager = TabManager()
        let result = manager.finderCopyURL(for: baseURL, fileExists: { _ in false })

        #expect(result?.lastPathComponent == "file copy.swift")
    }

    @Test("TabManager: skips existing copies and increments counter")
    func tabManagerSkipsExisting() {
        let manager = TabManager()
        let existing: Set<String> = [
            "/tmp/test/file copy.swift",
            "/tmp/test/file copy 2.swift"
        ]
        let result = manager.finderCopyURL(for: baseURL) { existing.contains($0) }

        #expect(result?.lastPathComponent == "file copy 3.swift")
    }

    @Test("TabManager: returns nil when all names are taken (graceful fallback)")
    func tabManagerReturnsNilWhenExhausted() {
        let manager = TabManager()
        let result = manager.finderCopyURL(for: baseURL, fileExists: { _ in true })

        #expect(result == nil)
    }

    @Test("TabManager: handles files without extension")
    func tabManagerNoExtension() {
        let manager = TabManager()
        let result = manager.finderCopyURL(for: noExtURL, fileExists: { _ in false })

        #expect(result?.lastPathComponent == "Makefile copy")
    }

    @Test("TabManager: max attempts matches declared constant")
    func tabManagerMaxAttempts() {
        #expect(TabManager.maxCopyAttempts == 10_000)
    }

    @Test("TabManager: tries exactly maxCopyAttempts candidates before returning nil")
    func tabManagerExactAttemptCount() {
        let manager = TabManager()
        var callCount = 0
        let result = manager.finderCopyURL(for: baseURL) { _ in
            callCount += 1
            return true
        }

        #expect(result == nil)
        #expect(callCount == TabManager.maxCopyAttempts)
    }

    // MARK: - SidebarEditState.finderCopyURL

    @Test("SidebarEditState: returns 'file copy.ext' when no copies exist")
    func sidebarFirstCopy() {
        let result = SidebarEditState.finderCopyURL(for: baseURL, fileExists: { _ in false })

        #expect(result?.lastPathComponent == "file copy.swift")
    }

    @Test("SidebarEditState: returns nil when all names are taken (graceful fallback)")
    func sidebarReturnsNilWhenExhausted() {
        let result = SidebarEditState.finderCopyURL(for: baseURL, fileExists: { _ in true })

        #expect(result == nil)
    }

    @Test("SidebarEditState: skips existing copies and increments counter")
    func sidebarSkipsExisting() {
        let existing: Set<String> = [
            "/tmp/test/file copy.swift"
        ]
        let result = SidebarEditState.finderCopyURL(for: baseURL) { existing.contains($0) }

        #expect(result?.lastPathComponent == "file copy 2.swift")
    }

    @Test("SidebarEditState: tries exactly maxCopyAttempts candidates before returning nil")
    func sidebarExactAttemptCount() {
        var callCount = 0
        let result = SidebarEditState.finderCopyURL(for: baseURL) { _ in
            callCount += 1
            return true
        }

        #expect(result == nil)
        #expect(callCount == SidebarEditState.maxCopyAttempts)
    }
}
