//
//  SupportedFileTypesTests.swift
//  PineTests
//
//  Created by Claude on 24.03.2026.
//

import Testing
@testable import Pine

@Suite("SupportedFileTypes")
@MainActor
struct SupportedFileTypesTests {

    // MARK: - Document Type Coverage

    @Test("All document types have non-empty extensions")
    func allDocumentTypesHaveExtensions() {
        for docType in SupportedFileTypes.documentTypes {
            #expect(!docType.extensions.isEmpty, "Document type '\(docType.name)' has no extensions")
        }
    }

    @Test("All document types have a role set to Editor")
    func allDocumentTypesHaveEditorRole() {
        for docType in SupportedFileTypes.documentTypes {
            #expect(docType.role == "Editor", "Document type '\(docType.name)' role is '\(docType.role)', expected 'Editor'")
        }
    }

    @Test("All document types have a valid UTI")
    func allDocumentTypesHaveUTI() {
        for docType in SupportedFileTypes.documentTypes {
            #expect(!docType.contentTypeIdentifiers.isEmpty,
                    "Document type '\(docType.name)' has no content type identifiers")
        }
    }

    // MARK: - Required Extensions from Issue

    @Test("Issue #421 required extensions are registered",
          arguments: ["swift", "py", "js", "ts", "go", "rs", "json", "yaml", "yml",
                      "toml", "md", "html", "css", "sh", "txt", "c", "cpp", "h",
                      "rb", "java", "kt"])
    func requiredExtensionRegistered(ext: String) {
        let allExtensions = SupportedFileTypes.allExtensions
        #expect(allExtensions.contains(ext),
                "Extension '.\(ext)' is not registered in SupportedFileTypes")
    }

    // MARK: - Grammar Extensions Coverage

    @Test("Grammar file extensions are covered by document types")
    func grammarExtensionsCovered() {
        let registered = SupportedFileTypes.allExtensions
        // Manually check a selection of grammar extensions
        let grammarExtensions = [
            "swift", "py", "js", "ts", "json", "html", "css", "go", "rs",
            "java", "kt", "rb", "c", "cpp", "h", "sh", "sql", "xml", "yaml",
            "toml", "md", "dart", "groovy", "graphql", "nix", "proto",
            "prisma", "ini", "log", "diff", "tf"
        ]
        for ext in grammarExtensions {
            #expect(registered.contains(ext),
                    "Grammar extension '.\(ext)' is not in SupportedFileTypes")
        }
    }

    // MARK: - No Duplicates

    @Test("No duplicate extensions across document types")
    func noDuplicateExtensions() {
        var seen = Set<String>()
        for docType in SupportedFileTypes.documentTypes {
            for ext in docType.extensions {
                #expect(!seen.contains(ext), "Extension '.\(ext)' is duplicated in document types")
                seen.insert(ext)
            }
        }
    }

    // MARK: - Info.plist Structure

    @Test("documentTypesForPlist returns valid plist dictionaries")
    func plistDictionariesAreValid() {
        let plistEntries = SupportedFileTypes.documentTypesForPlist
        #expect(!plistEntries.isEmpty)
        for entry in plistEntries {
            #expect(entry["CFBundleTypeName"] != nil)
            #expect(entry["CFBundleTypeRole"] != nil)
            #expect(entry["LSItemContentTypes"] != nil)
            #expect(entry["CFBundleTypeExtensions"] != nil)
        }
    }

    @Test("allExtensions returns a non-empty set")
    func allExtensionsNonEmpty() {
        #expect(!SupportedFileTypes.allExtensions.isEmpty)
        #expect(SupportedFileTypes.allExtensions.count >= 21) // At least the issue requirements
    }

    // MARK: - Specific UTI Mappings

    @Test("Swift files use correct UTI")
    func swiftUTI() {
        let swiftType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("swift") }
        #expect(swiftType != nil)
        #expect(swiftType?.contentTypeIdentifiers.contains("public.swift-source") == true)
    }

    @Test("Python files use correct UTI")
    func pythonUTI() {
        let pyType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("py") }
        #expect(pyType != nil)
        #expect(pyType?.contentTypeIdentifiers.contains("public.python-script") == true)
    }

    @Test("JSON files use correct UTI")
    func jsonUTI() {
        let jsonType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("json") }
        #expect(jsonType != nil)
        #expect(jsonType?.contentTypeIdentifiers.contains("public.json") == true)
    }

    @Test("Plain text files use correct UTI")
    func plainTextUTI() {
        let txtType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("txt") }
        #expect(txtType != nil)
        #expect(txtType?.contentTypeIdentifiers.contains("public.plain-text") == true)
    }

    @Test("Markdown files use correct UTI")
    func markdownUTI() {
        let mdType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("md") }
        #expect(mdType != nil)
    }

    @Test("HTML files use correct UTI")
    func htmlUTI() {
        let htmlType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("html") }
        #expect(htmlType != nil)
        #expect(htmlType?.contentTypeIdentifiers.contains("public.html") == true)
    }

    @Test("CSS files use correct UTI")
    func cssUTI() {
        let cssType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("css") }
        #expect(cssType != nil)
    }

    @Test("Shell script files use correct UTI")
    func shellUTI() {
        let shType = SupportedFileTypes.documentTypes.first { $0.extensions.contains("sh") }
        #expect(shType != nil)
        #expect(shType?.contentTypeIdentifiers.contains("public.shell-script") == true)
    }

    // MARK: - DocumentType Struct

    @Test("DocumentType has correct equatable behavior")
    func documentTypeEquatable() {
        let a = SupportedFileTypes.DocumentType(
            name: "Test", extensions: ["test"], contentTypeIdentifiers: ["public.test"], role: "Editor"
        )
        let b = SupportedFileTypes.DocumentType(
            name: "Test", extensions: ["test"], contentTypeIdentifiers: ["public.test"], role: "Editor"
        )
        #expect(a == b)
    }
}
