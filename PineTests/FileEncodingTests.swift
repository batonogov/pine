//
//  FileEncodingTests.swift
//  PineTests
//
//  Tests for file encoding detection and preservation.
//

import Foundation
import Testing

@testable import Pine

@Suite("File Encoding Detection Tests")
struct FileEncodingTests {

    /// Creates a temporary file with specific encoding.
    private func tempFileURL(
        name: String = "test.txt",
        content: String,
        encoding: String.Encoding
    ) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: encoding)
        return url
    }

    /// Creates a temporary file from raw bytes.
    private func tempFileURL(name: String = "test.txt", data: Data) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    // MARK: - EditorTab encoding property

    @Test("EditorTab stores encoding, defaults to UTF-8")
    func editorTabDefaultEncoding() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "hello")
        #expect(tab.encoding == .utf8)
    }

    @Test("EditorTab stores custom encoding")
    func editorTabCustomEncoding() {
        var tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.txt"), content: "hello")
        tab.encoding = .utf16
        #expect(tab.encoding == .utf16)
    }

    // MARK: - Loading files with different encodings

    @Test("Open UTF-8 file detects UTF-8 encoding")
    func openUTF8File() {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello, world!", encoding: .utf8)

        manager.openTab(url: url)

        #expect(manager.activeTab?.content == "Hello, world!")
        #expect(manager.activeTab?.encoding == .utf8)
    }

    @Test("Open UTF-16 file detects UTF-16 encoding")
    func openUTF16File() {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello, world!", encoding: .utf16)

        manager.openTab(url: url)

        #expect(manager.activeTab?.content == "Hello, world!")
        #expect(manager.activeTab?.encoding == .utf16)
    }

    @Test("Open UTF-16 Big Endian file detects encoding")
    func openUTF16BEFile() {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello, world!", encoding: .utf16BigEndian)

        // UTF-16 BE without BOM — write with BOM manually
        let bom: [UInt8] = [0xFE, 0xFF]
        var data = Data(bom)
        if let encoded = "Hello, world!".data(using: .utf16BigEndian) {
            data.append(encoded)
        }
        let bomUrl = tempFileURL(name: "test_be.txt", data: data)

        manager.openTab(url: bomUrl)

        #expect(manager.activeTab?.content == "Hello, world!")
    }

    @Test("Open Latin-1 file with non-ASCII characters")
    func openLatin1File() {
        let manager = TabManager()
        // Latin-1 string with accented characters
        let content = "café résumé"
        let url = tempFileURL(content: content, encoding: .isoLatin1)

        manager.openTab(url: url)

        // Content should be decoded correctly
        #expect(manager.activeTab?.content == content)
        // NSString detection may report windowsCP1252 for Latin-1 content
        // since CP1252 is a superset of ISO 8859-1 — both decode this content identically
        let enc = manager.activeTab?.encoding
        #expect(enc == .isoLatin1 || enc == .windowsCP1252)
    }

    @Test("Open Windows-1251 file with Cyrillic characters")
    func openWindows1251File() {
        let manager = TabManager()
        let content = "Привет мир"
        let url = tempFileURL(content: content, encoding: .windowsCP1251)

        manager.openTab(url: url)

        #expect(manager.activeTab?.content == content)
        #expect(manager.activeTab?.encoding == .windowsCP1251)
    }

    // MARK: - Saving preserves encoding

    @Test("Save preserves UTF-16 encoding")
    func savePreservesUTF16() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello", encoding: .utf16)

        manager.openTab(url: url)
        manager.updateContent("Modified")

        let success = manager.saveActiveTab()
        #expect(success == true)

        // Read back with UTF-16 to verify encoding was preserved
        let onDisk = try String(contentsOf: url, encoding: .utf16)
        #expect(onDisk == "Modified")
    }

    @Test("Save preserves Latin-1 encoding")
    func savePreservesLatin1() throws {
        let manager = TabManager()
        let content = "café"
        let url = tempFileURL(content: content, encoding: .isoLatin1)

        manager.openTab(url: url)
        manager.updateContent("résumé")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try String(contentsOf: url, encoding: .isoLatin1)
        #expect(onDisk == "résumé")
    }

    @Test("Save As preserves encoding")
    func saveAsPreservesEncoding() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello", encoding: .utf16)

        manager.openTab(url: url)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let newURL = dir.appendingPathComponent("saved_as.txt")

        try manager.saveActiveTabAs(to: newURL)

        let onDisk = try String(contentsOf: newURL, encoding: .utf16)
        #expect(onDisk == "Hello")
    }

    @Test("Duplicate preserves encoding")
    func duplicatePreservesEncoding() throws {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("file.txt")
        try "Hello".write(to: url, atomically: true, encoding: .utf16)

        manager.openTab(url: url)
        #expect(manager.activeTab?.encoding == .utf16)

        let duplicated = manager.duplicateActiveTab()
        #expect(duplicated == true)
        #expect(manager.activeTab?.encoding == .utf16)
    }

    // MARK: - Reopen with different encoding

    @Test("Reopen tab with different encoding changes content and encoding")
    func reopenWithDifferentEncoding() {
        let manager = TabManager()
        // Create a file that's valid in both Latin-1 and UTF-8
        let content = "Hello"
        let url = tempFileURL(content: content, encoding: .utf8)

        manager.openTab(url: url)
        #expect(manager.activeTab?.encoding == .utf8)

        manager.reopenActiveTab(withEncoding: .isoLatin1)

        #expect(manager.activeTab?.encoding == .isoLatin1)
        #expect(manager.activeTab?.content == content)
    }

    // MARK: - Encoding display name

    @Test("Encoding display name for common encodings")
    func encodingDisplayNames() {
        #expect(String.Encoding.utf8.displayName == "UTF-8")
        #expect(String.Encoding.utf16.displayName == "UTF-16")
        #expect(String.Encoding.utf16BigEndian.displayName == "UTF-16 BE")
        #expect(String.Encoding.utf16LittleEndian.displayName == "UTF-16 LE")
        #expect(String.Encoding.isoLatin1.displayName == "ISO Latin 1")
        #expect(String.Encoding.windowsCP1251.displayName == "Windows-1251")
        #expect(String.Encoding.ascii.displayName == "ASCII")
        #expect(String.Encoding.japaneseEUC.displayName == "EUC-JP")
        #expect(String.Encoding.shiftJIS.displayName == "Shift JIS")
    }

    // MARK: - External change detection preserves encoding

    @Test("Silent reload of clean tab preserves encoding")
    func silentReloadPreservesEncoding() {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello", encoding: .utf16)

        manager.openTab(url: url)
        #expect(manager.activeTab?.encoding == .utf16)

        // Simulate external modification
        try? "Modified".write(to: url, atomically: true, encoding: .utf16)

        // Touch file to advance modification date
        let futureDate = Date().addingTimeInterval(10)
        try? FileManager.default.setAttributes(
            [.modificationDate: futureDate], ofItemAtPath: url.path
        )

        _ = manager.checkExternalChanges()

        #expect(manager.activeTab?.encoding == .utf16)
        #expect(manager.activeTab?.content == "Modified")
    }

    @Test("Reload tab preserves encoding")
    func reloadPreservesEncoding() {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello", encoding: .utf16)

        manager.openTab(url: url)
        #expect(manager.activeTab?.encoding == .utf16)

        try? "Reloaded".write(to: url, atomically: true, encoding: .utf16)
        manager.reloadTab(url: url)

        #expect(manager.activeTab?.encoding == .utf16)
        #expect(manager.activeTab?.content == "Reloaded")
    }

    // MARK: - Pure ASCII detected as UTF-8

    @Test("Pure ASCII file detected as UTF-8")
    func pureASCIIDetectedAsUTF8() {
        let manager = TabManager()
        let url = tempFileURL(content: "int main() { return 0; }", encoding: .ascii)

        manager.openTab(url: url)

        // ASCII is a subset of UTF-8, so we should detect it as UTF-8
        #expect(manager.activeTab?.encoding == .utf8)
    }
}
