//
//  LSPManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct LSPManagerTests {

    // MARK: - Language Detection

    @Test func swiftExtensionMapsToSwift() {
        let manager = LSPManager()
        let langId = manager.languageIdForExtension("swift")
        #expect(langId == "swift")
    }

    @Test func tsExtensionMapsToTypeScript() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("ts") == "typescript")
        #expect(manager.languageIdForExtension("tsx") == "typescript")
    }

    @Test func jsExtensionMapsToJavaScript() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("js") == "javascript")
        #expect(manager.languageIdForExtension("jsx") == "javascript")
    }

    @Test func pythonExtensionMapsToPython() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("py") == "python")
    }

    @Test func goExtensionMapsToGo() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("go") == "go")
    }

    @Test func rustExtensionMapsToRust() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("rs") == "rust")
    }

    @Test func cExtensionMapsToC() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("c") == "c")
        #expect(manager.languageIdForExtension("h") == "c")
    }

    @Test func cppExtensionMapsToCpp() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("cpp") == "cpp")
        #expect(manager.languageIdForExtension("cc") == "cpp")
        #expect(manager.languageIdForExtension("cxx") == "cpp")
        #expect(manager.languageIdForExtension("hpp") == "cpp")
        #expect(manager.languageIdForExtension("hxx") == "cpp")
    }

    @Test func unknownExtensionReturnsNil() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("txt") == nil)
        #expect(manager.languageIdForExtension("md") == nil)
        #expect(manager.languageIdForExtension("json") == nil)
        #expect(manager.languageIdForExtension("xml") == nil)
    }

    @Test func extensionLookupIsCaseInsensitive() {
        let manager = LSPManager()
        #expect(manager.languageIdForExtension("Swift") == "swift")
        #expect(manager.languageIdForExtension("SWIFT") == "swift")
        #expect(manager.languageIdForExtension("PY") == "python")
        #expect(manager.languageIdForExtension("Rs") == "rust")
    }

    // MARK: - Config Lookup

    @Test func configForSwiftExtension() {
        let manager = LSPManager()
        let config = manager.configForExtension("swift")
        #expect(config?.languageId == "swift")
        #expect(config?.serverPath == "/usr/bin/xcrun")
        #expect(config?.arguments == ["sourcekit-lsp"])
    }

    @Test func configForUnknownExtensionIsNil() {
        let manager = LSPManager()
        let config = manager.configForExtension("unknown")
        #expect(config == nil)
    }

    // MARK: - Custom Configs

    @Test func customConfigsOverrideDefaults() {
        let custom = LSPManager.ServerConfig(
            languageId: "ruby",
            serverPath: "/usr/local/bin/solargraph",
            arguments: ["stdio"],
            extensions: ["rb"]
        )
        let manager = LSPManager(configs: [custom])
        #expect(manager.languageIdForExtension("rb") == "ruby")
        #expect(manager.languageIdForExtension("swift") == nil)
    }

    @Test func emptyConfigsMeansNoLanguageSupport() {
        let manager = LSPManager(configs: [])
        #expect(manager.languageIdForExtension("swift") == nil)
        #expect(manager.languageIdForExtension("py") == nil)
    }

    // MARK: - Client Lookup

    @Test func clientForUnstartedLanguageIsNil() {
        let manager = LSPManager()
        #expect(manager.clientForLanguage("swift") == nil)
    }

    // MARK: - Document URI

    @Test func documentUriFromFileURL() {
        let url = URL(fileURLWithPath: "/Users/test/project/main.swift")
        let uri = LSPManager.documentUri(for: url)
        #expect(uri == "file:///Users/test/project/main.swift")
    }

    @Test func rootUriFromDirectoryURL() {
        let url = URL(fileURLWithPath: "/Users/test/project/")
        let uri = LSPManager.rootUri(for: url)
        #expect(uri.hasPrefix("file:///Users/test/project"))
    }

    @Test func documentUriHandlesSpaces() {
        let url = URL(fileURLWithPath: "/Users/test/my project/file.swift")
        let uri = LSPManager.documentUri(for: url)
        #expect(uri.contains("my%20project"))
    }

    // MARK: - Root URI

    @Test func setRootUri() {
        let manager = LSPManager()
        // Should not crash — this is a basic setter test
        manager.setRootUri("file:///test")
        manager.setRootUri(nil)
    }

    // MARK: - Default Configs Validation

    @Test func defaultConfigsHaveValidStructure() {
        let configs = LSPManager.defaultConfigs
        #expect(!configs.isEmpty)
        for config in configs {
            #expect(!config.languageId.isEmpty)
            #expect(!config.serverPath.isEmpty)
            #expect(!config.extensions.isEmpty)
        }
    }

    @Test func defaultConfigsHaveUniqueLanguageIds() {
        let configs = LSPManager.defaultConfigs
        let ids = configs.map(\.languageId)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test func defaultConfigsExtensionsDontOverlap() {
        let configs = LSPManager.defaultConfigs
        var seen = Set<String>()
        for config in configs {
            for ext in config.extensions {
                #expect(!seen.contains(ext), "Duplicate extension: \(ext)")
                seen.insert(ext)
            }
        }
    }

    // MARK: - ServerConfig Equatable

    @Test func serverConfigEquality() {
        let a = LSPManager.ServerConfig(
            languageId: "swift",
            serverPath: "/usr/bin/xcrun",
            arguments: ["sourcekit-lsp"],
            extensions: ["swift"]
        )
        let b = LSPManager.ServerConfig(
            languageId: "swift",
            serverPath: "/usr/bin/xcrun",
            arguments: ["sourcekit-lsp"],
            extensions: ["swift"]
        )
        let c = LSPManager.ServerConfig(
            languageId: "python",
            serverPath: "/usr/local/bin/pylsp",
            extensions: ["py"]
        )
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Shutdown

    @Test func shutdownAllWithNoClientsCompletes() async {
        let manager = LSPManager()
        await withCheckedContinuation { continuation in
            manager.shutdownAll {
                continuation.resume()
            }
        }
    }
}
