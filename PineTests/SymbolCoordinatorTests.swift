//
//  SymbolCoordinatorTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Symbol Coordinator Tests")
struct SymbolCoordinatorTests {
    @Test("Regex provider preserves supported offline behavior")
    func regexProviderFallback() async throws {
        let text = "class Local {\n    func work() {}\n}"
        let snapshot = DocumentSnapshot(
            uri: "file:///Local.swift",
            text: text,
            revision: DocumentRevision(1)
        )
        let provider = RegexSymbolProvider(fileExtension: "swift")

        let symbols = try #require(
            await provider.symbols(for: snapshot)
        )

        #expect(symbols.map(\.name) == ["Local", "work"])
        #expect(symbols.allSatisfy { $0.children.isEmpty })
        #expect(symbols[0].selectionRange.location == 6)
    }

    @Test("Unsupported regex language remains empty")
    func unsupportedRegexLanguage() async {
        let snapshot = DocumentSnapshot(
            uri: "file:///file.unknown",
            text: "class Local {}",
            revision: DocumentRevision(1)
        )
        let provider = RegexSymbolProvider(fileExtension: "unknown")

        #expect(!provider.canProvide(for: snapshot))
        #expect(await provider.symbols(for: snapshot) == nil)
    }

    @Test(
        "Malformed fixtures retain symbols for supported local languages"
    )
    func malformedInitialLanguageFixtures() async throws {
        let fixtures: [
            (
                language: String,
                fileExtension: String,
                text: String,
                expectedNames: [String]
            )
        ] = [
            (
                "swift",
                "swift",
                "class SwiftContainer {\n    func nested(",
                ["SwiftContainer", "nested"]
            ),
            (
                "typescript",
                "ts",
                "export interface TSShape {\nexport function compute(",
                ["TSShape", "compute"]
            ),
            (
                "python",
                "py",
                "class PythonContainer:\n    def nested(",
                ["PythonContainer", "nested"]
            )
        ]

        for fixture in fixtures {
            let snapshot = DocumentSnapshot(
                uri:
                    "file:///fixture."
                    + fixture.fileExtension,
                text: fixture.text,
                revision: DocumentRevision(1)
            )
            let provider = RegexSymbolProvider(
                fileExtension: fixture.fileExtension
            )
            let symbols = try #require(
                await provider.symbols(for: snapshot)
            )

            #expect(
                symbols.map(\.name) == fixture.expectedNames,
                "Fallback failed for \(fixture.language)"
            )
        }
    }

    @Test("Navigator flattening preserves hierarchy and source lines")
    func navigatorFlattening() {
        let text = "Container\nmethod\nnested"
        let symbols = [
            node(
                "Container",
                kind: .class,
                at: 0,
                children: [
                    node(
                        "method",
                        at: 10,
                        children: [node("nested", at: 17)]
                    )
                ]
            )
        ]

        let snapshot = DocumentSnapshot(
            uri: "file:///hierarchy.swift",
            text: text,
            revision: DocumentRevision(1)
        )
        let entries = SymbolNavigatorEntry.flatten(
            symbols,
            snapshot: snapshot
        )

        #expect(entries.map(\.symbol.name) == [
            "Container",
            "method",
            "nested"
        ])
        #expect(entries.map(\.depth) == [0, 1, 2])
        #expect(entries.map(\.line) == [1, 2, 3])
        #expect(entries.map(\.id) == ["0", "0.0", "0.0.0"])
    }

    @Test("Navigator line numbers handle UTF-16, CRLF, and CR")
    func navigatorLineNumbersUseUTF16Coordinates() {
        let text = "😀\r\n外\rchild"
        let symbols = [
            node("外", at: 4),
            node("child", at: 6)
        ]

        let snapshot = DocumentSnapshot(
            uri: "file:///coordinates.swift",
            text: text,
            revision: DocumentRevision(1)
        )
        let entries = SymbolNavigatorEntry.flatten(
            symbols,
            snapshot: snapshot
        )

        #expect(entries.map(\.line) == [2, 3])
    }

    @Test("Navigator entries reject a changed tab or document snapshot")
    func navigatorEntriesRejectStaleSnapshot() throws {
        let coordinator = SymbolCoordinator()
        let snapshot = DocumentSnapshot(
            uri: "file:///first.swift",
            text: "func first() {}",
            revision: coordinator.beginRevision()
        )
        let entry = try #require(
            SymbolNavigatorEntry.flatten(
                [node("first", at: 5)],
                snapshot: snapshot
            ).first
        )

        #expect(
            entry.matches(
                url: URL(fileURLWithPath: "/first.swift"),
                text: snapshot.text
            )
        )
        #expect(
            !entry.matches(
                url: URL(fileURLWithPath: "/second.swift"),
                text: snapshot.text
            )
        )
        #expect(
            !entry.matches(
                url: URL(fileURLWithPath: "/first.swift"),
                text: "func changed() {}"
            )
        )

        _ = coordinator.beginRevision()
        #expect(!coordinator.isCurrent(entry.snapshot.revision))
    }

    @Test("Every symbol kind uses the requested language and English fallback", arguments: [
        (SymbolKind.class, "Класс", "Class"),
        (SymbolKind.struct, "Структура", "Struct"),
        (SymbolKind.enum, "Перечисление", "Enum"),
        (SymbolKind.interface, "Интерфейс", "Interface"),
        (SymbolKind.namespace, "Пространство имён", "Namespace"),
        (SymbolKind.function, "Функция", "Function"),
        (SymbolKind.property, "Свойство", "Property"),
        (SymbolKind.variable, "Переменная", "Variable"),
        (SymbolKind.other, "Символ", "Symbol"),
    ])
    func symbolKindLabelsAreLocalized(
        kind: SymbolKind,
        russianLabel: String,
        fallbackLabel: String
    ) {
        let russian = Locale(identifier: "ru")
        let unsupported = Locale(identifier: "zz-ZZ")

        #expect(Strings.symbolKindName(kind, locale: russian) == russianLabel)
        #expect(
            Strings.symbolKindName(kind, locale: unsupported) == fallbackLabel
        )
    }

    private func node(
        _ name: String,
        kind: SymbolKind = .function,
        at location: Int,
        children: [DocumentSymbolNode] = []
    ) -> DocumentSymbolNode {
        let range = NSRange(
            location: location,
            length: (name as NSString).length
        )
        return DocumentSymbolNode(
            name: name,
            kind: kind,
            range: range,
            selectionRange: range,
            children: children
        )
    }

}
