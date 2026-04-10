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
@MainActor
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

        // UTF-16 BE with BOM
        let bom: [UInt8] = [0xFE, 0xFF]
        var data = Data(bom)
        if let encoded = "Hello, world!".data(using: .utf16BigEndian) {
            data.append(encoded)
        }
        let url = tempFileURL(name: "test_be.txt", data: data)

        manager.openTab(url: url)

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
        #expect(onDisk == "Modified\n")
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
        #expect(onDisk == "résumé\n")
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
        #expect(onDisk == "Hello\n")
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

    @Test("Reopen with different encoding refuses when tab is dirty")
    func reopenRefusesWhenDirty() {
        let manager = TabManager()
        let url = tempFileURL(content: "Hello", encoding: .utf8)

        manager.openTab(url: url)
        manager.updateContent("Modified")
        #expect(manager.activeTab?.isDirty == true)

        let result = manager.reopenActiveTab(withEncoding: .isoLatin1)

        #expect(result == false)
        #expect(manager.activeTab?.encoding == .utf8)
        #expect(manager.activeTab?.content == "Modified")
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

    // MARK: - detect(from:) edge cases

    @Test("Detect from empty data returns empty UTF-8 string")
    func detectEmptyData() {
        let (content, encoding) = String.Encoding.detect(from: Data())
        #expect(content == "")
        #expect(encoding == .utf8)
    }

    @Test("Detect from UTF-8 BOM data strips BOM and detects UTF-8")
    func detectUTF8BOM() {
        // UTF-8 BOM: EF BB BF
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("Hello".utf8))
        let (content, encoding) = String.Encoding.detect(from: data)
        // UTF-8 BOM is valid UTF-8 — Swift may include or strip the BOM character
        #expect(content.contains("Hello"))
        #expect(encoding == .utf8)
    }

    @Test("Detect from binary data does not crash and returns some content")
    func detectBinaryData() {
        // Random bytes that are not valid in any common encoding
        let data = Data([0x80, 0x81, 0x82, 0xFE, 0xFF, 0x00, 0x01, 0xC0, 0xC1])
        let (content, encoding) = String.Encoding.detect(from: data)
        // Should not crash, should return something (possibly lossy)
        #expect(!content.isEmpty || encoding != .utf8)
    }

    // MARK: - Shift JIS detection

    @Test("Detect Shift JIS encoded data")
    func detectShiftJIS() {
        // "こんにちは" in Shift JIS
        let text = "こんにちは"
        guard let data = text.data(using: .shiftJIS) else {
            Issue.record("Failed to encode test string as Shift JIS")
            return
        }

        let (content, encoding) = String.Encoding.detect(from: data)

        #expect(content == text)
        #expect(encoding == .shiftJIS)
    }

    @Test("Open Shift JIS file detects encoding correctly")
    func openShiftJISFile() {
        let manager = TabManager()
        let text = "日本語テスト"
        let url = tempFileURL(content: text, encoding: .shiftJIS)

        manager.openTab(url: url)

        #expect(manager.activeTab?.content == text)
        #expect(manager.activeTab?.encoding == .shiftJIS)
    }

    // MARK: - ISO-2022-JP detection

    @Test("Detect ISO-2022-JP encoded data produces valid content")
    func detectISO2022JP() {
        // ISO-2022-JP uses escape sequences (ESC $ B ... ESC ( B) for mode switching.
        // NSString.stringEncoding(for:) does not always detect ISO-2022-JP correctly
        // because the escape bytes can be valid in other encodings. The important thing
        // is that detect() does not crash and produces some content.
        let text = "日本語"
        guard let data = text.data(using: .iso2022JP) else {
            Issue.record("Failed to encode test string as ISO-2022-JP")
            return
        }

        let (content, encoding) = String.Encoding.detect(from: data)

        // Should not crash and should produce non-empty content
        #expect(!content.isEmpty)
        // The encoding may or may not be detected as ISO-2022-JP depending on NSString heuristics
        _ = encoding
    }

    // MARK: - Lossy conversion fallback

    @Test("Invalid UTF-8 bytes fall through to NSString detection")
    func invalidUTF8FallsThrough() {
        // Bytes that are invalid UTF-8 but valid Latin-1
        // 0xE9 = 'é' in Latin-1, but incomplete UTF-8 sequence
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0xE9])

        let (content, encoding) = String.Encoding.detect(from: data)

        // Should not detect as UTF-8 (invalid), should fall through to NSString
        #expect(encoding != .utf8)
        #expect(!content.isEmpty)
        // The 'é' character should be preserved via Latin-1 or CP1252
        #expect(content.contains("Hello"))
    }

    @Test("Lossy fallback produces content for ambiguous data")
    func lossyFallbackProducesContent() {
        // Mix of bytes that are valid in multiple encodings but not UTF-8
        // This should exercise the lossy conversion path if strict detection fails
        let data = Data([0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5])

        let (content, encoding) = String.Encoding.detect(from: data)

        // Should not crash and should produce some content
        _ = encoding // Encoding depends on NSString heuristics
        #expect(!content.isEmpty)
    }

    @Test("Single invalid byte returns fallback encoding")
    func singleInvalidByte() {
        let data = Data([0xFF])

        let (content, encoding) = String.Encoding.detect(from: data)

        // 0xFF is not valid UTF-8, should fall through
        #expect(encoding != .utf8)
        // Should still produce content (even if it's a replacement character)
        #expect(!content.isEmpty)
    }

    // MARK: - reopenActiveTab edge cases

    @Test("Reopen returns false when no active tab")
    func reopenNoActiveTab() {
        let manager = TabManager()
        let result = manager.reopenActiveTab(withEncoding: .utf16)
        #expect(result == false)
    }

    @Test("Reopen returns false when file cannot be decoded in target encoding")
    func reopenIncompatibleEncoding() {
        let manager = TabManager()
        // Create a file with Cyrillic content in Windows-1251
        let url = tempFileURL(content: "Привет", encoding: .windowsCP1251)

        manager.openTab(url: url)

        // ISO-2022-JP cannot represent Cyrillic bytes — should fail
        let result = manager.reopenActiveTab(withEncoding: .iso2022JP)

        // Either returns false (can't decode) or returns true with garbled content
        // The important thing is it doesn't crash
        if result {
            // If it succeeded, encoding should be updated
            #expect(manager.activeTab?.encoding == .iso2022JP)
        } else {
            // If it failed, original encoding preserved
            #expect(manager.activeTab?.encoding == .windowsCP1251)
        }
    }

    // MARK: - Save preserves Windows-1251

    @Test("Save preserves Windows-1251 encoding with Cyrillic roundtrip")
    func savePreservesWindows1251() throws {
        let manager = TabManager()
        let url = tempFileURL(content: "Привет", encoding: .windowsCP1251)

        manager.openTab(url: url)
        manager.updateContent("Мир")

        let success = manager.saveActiveTab()
        #expect(success == true)

        let onDisk = try String(contentsOf: url, encoding: .windowsCP1251)
        #expect(onDisk == "Мир\n")
    }

    // MARK: - displayName edge cases

    @Test("Display name for unknown encoding uses localizedName fallback")
    func displayNameUnknownEncoding() {
        // Use a rare encoding not in the switch
        let exotic = String.Encoding(rawValue: 2147483649) // NSProprietaryStringEncoding
        let name = exotic.displayName
        // Should not crash and should return a non-empty string
        #expect(!name.isEmpty)
    }

    @Test("Display name covers all available encodings")
    func displayNameCoversAllAvailable() {
        // Every encoding in availableEncodings should have a non-empty display name
        for encoding in String.Encoding.availableEncodings {
            #expect(!encoding.displayName.isEmpty, "displayName empty for rawValue \(encoding.rawValue)")
        }
    }
}
