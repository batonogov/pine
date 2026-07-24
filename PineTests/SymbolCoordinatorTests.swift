//
//  SymbolCoordinatorTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Symbol Coordinator Tests")
struct SymbolCoordinatorTests {
    @Test("Missing LSP provider keeps regex symbols")
    func noLSPKeepsRegex() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let regex = [node("local", at: 0)]

        let resolution = await coordinator.refine(
            snapshot: snapshot,
            regexSymbols: regex,
            lspProvider: nil
        )

        #expect(resolution == .resolved(regex, source: .regex))
    }

    @Test("Fresh non-empty LSP hierarchy owns the revision")
    func lspHierarchyWins() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let regex = [node("local", at: 0)]
        let lsp = [
            node(
                "Container",
                kind: .class,
                at: 0,
                children: [node("method", at: 6)]
            )
        ]
        let provider = StubSymbolProvider(symbols: lsp)

        let resolution = await coordinator.refine(
            snapshot: snapshot,
            regexSymbols: regex,
            lspProvider: provider
        )

        #expect(resolution == .resolved(lsp, source: .lsp))
    }

    @Test("Nil and empty LSP results deterministically fall back")
    func emptyResultsFallBack() async {
        let regex = [node("local", at: 0)]

        for result in [[DocumentSymbolNode]?](arrayLiteral: nil, []) {
            let coordinator = SymbolCoordinator()
            let snapshot = snapshot(coordinator: coordinator)
            let resolution = await coordinator.refine(
                snapshot: snapshot,
                regexSymbols: regex,
                lspProvider: StubSymbolProvider(symbols: result)
            )
            #expect(resolution == .resolved(regex, source: .regex))
        }
    }

    @Test("Provider capability decline avoids a request")
    func capabilityDeclineFallsBack() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let regex = [node("local", at: 0)]
        let provider = StubSymbolProvider(
            symbols: [node("remote", at: 0)],
            canProvide: false
        )

        let resolution = await coordinator.refine(
            snapshot: snapshot,
            regexSymbols: regex,
            lspProvider: provider
        )

        #expect(resolution == .resolved(regex, source: .regex))
        #expect(provider.requestCount == 0)
    }

    @Test("250 ms timeout keeps regex fallback")
    func timeoutFallsBack() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let regex = [node("local", at: 0)]
        let provider = StubSymbolProvider(
            symbols: [node("late", at: 0)],
            delay: .seconds(2)
        )

        let resolution = await coordinator.refine(
            snapshot: snapshot,
            regexSymbols: regex,
            lspProvider: provider
        )

        #expect(resolution == .resolved(regex, source: .regex))
    }

    @Test("Non-cooperative provider cannot extend the deadline")
    func nonCooperativeProviderIsBounded() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let regex = [node("local", at: 0)]
        let provider = StubSymbolProvider(
            symbols: [node("late", at: 0)],
            delay: .seconds(1),
            ignoresCancellation: true
        )

        let resolution = await coordinator.refine(
            snapshot: snapshot,
            regexSymbols: regex,
            lspProvider: provider
        )

        #expect(resolution == .resolved(regex, source: .regex))
    }

    @Test("Shared deadline gate records wall-clock timeout")
    nonisolated func sharedDeadlineGateIsBounded() async {
        let measurement = await StructuralDeadlineRace.runMeasured(
            deadline: .milliseconds(250)
        ) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + 1
                ) {
                    continuation.resume(returning: true)
                }
            }
        }

        guard case .timedOut = measurement.outcome else {
            Issue.record("Expected the shared deadline to win")
            return
        }
        #expect(
            measurement.elapsed < .milliseconds(750),
            "Gate timing must exclude delayed test-executor resumption"
        )
    }

    @Test("Cancellation keeps regex fallback")
    func cancellationFallsBack() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let regex = [node("local", at: 0)]
        let provider = StubSymbolProvider(
            symbols: [node("late", at: 0)],
            delay: .seconds(1),
            ignoresCancellation: true
        )
        let task = Task {
            await coordinator.refine(
                snapshot: snapshot,
                regexSymbols: regex,
                lspProvider: provider
            )
        }
        try? await Task.sleep(for: .milliseconds(20))

        task.cancel()

        #expect(
            await task.value == .resolved(regex, source: .regex)
        )
    }

    @Test("Stale provider result is discarded")
    func staleResultIsDiscarded() async {
        let coordinator = SymbolCoordinator()
        let snapshot = snapshot(coordinator: coordinator)
        let provider = StubSymbolProvider(
            symbols: [node("old", at: 0)],
            delay: .milliseconds(100)
        )
        let task = Task {
            await coordinator.refine(
                snapshot: snapshot,
                regexSymbols: [],
                lspProvider: provider
            )
        }
        try? await Task.sleep(for: .milliseconds(20))

        _ = coordinator.beginRevision()

        #expect(await task.value == .stale)
    }

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
        "Malformed fixtures retain symbols for every configured LSP language"
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

        #expect(
            Set(fixtures.map(\.language))
                == Set(LanguageServerRegistry.supportedLanguages)
        )
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

    @Test(
        "Valid fixtures preserve hierarchy for every configured LSP language"
    )
    func validInitialLanguageFixtures() throws {
        let fixtures: [ValidSymbolFixture] = [
            ValidSymbolFixture(
                language: "swift",
                fileExtension: "swift",
                text: "class SwiftContainer {\n    func nested() {}\n}",
                symbol: lspSymbol(
                    name: "SwiftContainer",
                    kind: 5,
                    range: lspRange(0, 0, 2, 1),
                    selection: lspRange(0, 6, 0, 20),
                    children: [
                        lspSymbol(
                            name: "nested",
                            kind: 12,
                            range: lspRange(1, 4, 1, 20),
                            selection: lspRange(1, 9, 1, 15)
                        )
                    ]
                ),
                expectedNames: ["SwiftContainer", "nested"]
            ),
            ValidSymbolFixture(
                language: "typescript",
                fileExtension: "ts",
                text: "class TSContainer {\n  method() {}\n}",
                symbol: lspSymbol(
                    name: "TSContainer",
                    kind: 5,
                    range: lspRange(0, 0, 2, 1),
                    selection: lspRange(0, 6, 0, 17),
                    children: [
                        lspSymbol(
                            name: "method",
                            kind: 6,
                            range: lspRange(1, 2, 1, 13),
                            selection: lspRange(1, 2, 1, 8)
                        )
                    ]
                ),
                expectedNames: ["TSContainer", "method"]
            ),
            ValidSymbolFixture(
                language: "python",
                fileExtension: "py",
                text: "class PythonContainer:\n    def nested():\n        pass",
                symbol: lspSymbol(
                    name: "PythonContainer",
                    kind: 5,
                    range: lspRange(0, 0, 2, 12),
                    selection: lspRange(0, 6, 0, 21),
                    children: [
                        lspSymbol(
                            name: "nested",
                            kind: 12,
                            range: lspRange(1, 4, 2, 12),
                            selection: lspRange(1, 8, 1, 14)
                        )
                    ]
                ),
                expectedNames: ["PythonContainer", "nested"]
            )
        ]

        #expect(
            Set(fixtures.map(\.language))
                == Set(LanguageServerRegistry.supportedLanguages)
        )
        for fixture in fixtures {
            let snapshot = DocumentSnapshot(
                uri:
                    "file:///fixture."
                    + fixture.fileExtension,
                text: fixture.text,
                revision: DocumentRevision(1)
            )
            let symbols = try #require(
                LSPDocumentSymbolProvider.normalize(
                    [fixture.symbol],
                    snapshot: snapshot
                )
            )
            let entries = SymbolNavigatorEntry.flatten(
                symbols,
                snapshot: snapshot
            )

            #expect(
                entries.map(\.symbol.name)
                    == fixture.expectedNames,
                "Hierarchy failed for \(fixture.language)"
            )
            #expect(entries.map(\.depth) == [0, 1])
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
    func navigatorLineNumbersUseLSPCoordinates() {
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

    @Test("New symbol kinds use localized labels")
    func symbolKindLabelsAreLocalized() {
        let russian = Locale(identifier: "ru")
        #expect(
            Strings.symbolKindName(.namespace, locale: russian)
                == "Пространство имён"
        )
        #expect(
            Strings.symbolKindName(.variable, locale: russian)
                == "Переменная"
        )
        #expect(
            Strings.symbolKindName(.other, locale: russian)
                == "Символ"
        )
    }

    private func snapshot(
        coordinator: SymbolCoordinator
    ) -> DocumentSnapshot {
        DocumentSnapshot(
            uri: "file:///test.swift",
            text: "local remote",
            revision: coordinator.beginRevision()
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

    private func lspSymbol(
        name: String,
        kind: Int,
        range: LSPRange,
        selection: LSPRange,
        children: [LSPDocumentSymbol] = []
    ) -> LSPDocumentSymbol {
        LSPDocumentSymbol(
            name: name,
            kind: kind,
            range: range,
            selectionRange: selection,
            children: children
        )
    }

    private func lspRange(
        _ startLine: Int,
        _ startCharacter: Int,
        _ endLine: Int,
        _ endCharacter: Int
    ) -> LSPRange {
        LSPRange(
            start: LSPPosition(
                line: startLine,
                character: startCharacter
            ),
            end: LSPPosition(
                line: endLine,
                character: endCharacter
            )
        )
    }
}

nonisolated private struct ValidSymbolFixture: Sendable {
    let language: String
    let fileExtension: String
    let text: String
    let symbol: LSPDocumentSymbol
    let expectedNames: [String]
}

nonisolated private final class StubSymbolProvider:
    SymbolProviding,
    @unchecked Sendable {

    private let result: [DocumentSymbolNode]?
    private let canProvideResult: Bool
    private let delay: Duration
    private let ignoresCancellation: Bool
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    init(
        symbols: [DocumentSymbolNode]?,
        canProvide: Bool = true,
        delay: Duration = .zero,
        ignoresCancellation: Bool = false
    ) {
        self.result = symbols
        self.canProvideResult = canProvide
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        canProvideResult
    }

    func symbols(
        for snapshot: DocumentSnapshot
    ) async -> [DocumentSymbolNode]? {
        lock.withLock { requests += 1 }
        if delay > .zero {
            if ignoresCancellation {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + delay.timeInterval
                    ) {
                        continuation.resume()
                    }
                }
            } else {
                try? await Task.sleep(for: delay)
            }
        }
        return result
    }
}

nonisolated private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
