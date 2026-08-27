//
//  ProductionViewUsageGuardTests.swift
//  PineTests
//
//  Guards against production views that nothing in production references
//  (#1561).
//

import Foundation
import Testing

/// The `CommandOverlayView` class of finding, encoded as a test (#1561).
///
/// `CommandOverlayView` compiled into the app bundle for several releases
/// with no production call site — every navigation flow it was written for
/// had moved to `CommandOverlayWindow`. The only code instantiating it was
/// tests, so the tree *looked* covered while no user could ever run it, and
/// a triage checklist was filed against a spring animation nobody had ever
/// seen. This guard fails the build the release that happens, not years
/// later.
///
/// The check is deliberately textual, not a call graph: a `struct … : View`
/// in `Pine/` whose name appears in no production file — outside comments
/// and string literals, which are stripped before matching — is either dead
/// or test-only. A reference does not prove reachability, but "no reference
/// anywhere in `Pine/`" was exactly true for `CommandOverlayView` and is a
/// strong enough signal to fail CI.
///
/// Legitimate escapes (per #1561):
/// - `private` / `fileprivate` views are file-scoped by construction.
/// - A view used elsewhere in its own file (a parent view's body, a
///   `#Preview`) is live for this guard's purposes.
/// - Deliberate exceptions live in `allowedUnusedViews`, each with a
///   reason; the companion test below fails when an entry stops naming a
///   declared view, so the list cannot rot into a blanket opt-out.
@Suite("Production view usage guard")
struct ProductionViewUsageGuardTests {

    // MARK: - The repository tree

    @Test("Every production View struct is referenced from production code")
    func everyProductionViewIsReferenced() throws {
        let sources = try Self.strippedProductionSources()

        // A vacuous scan must fail, not pass (#1508): if the declaration
        // finder ever goes blind, these floors turn that into a red test
        // instead of a green guard that checks nothing.
        #expect(sources.count > 100, "The production scan lost the tree")
        #expect(
            try Self.viewDeclarations(in: sources)
                .map(\.name)
                .contains("ContentView"),
            "The scan no longer finds ContentView — it is not scanning views"
        )

        let unreferenced = try Self.unreferencedViews(in: sources)
        let offenders = unreferenced
            .filter { Self.allowedUnusedViews[$0.name] == nil }
            .map { "\($0.name) (\($0.path))" }

        // Built as a `Comment` from a plain String: a concatenated value
        // does not convert to the `Comment?` parameter the way a string
        // literal does, and the long chain in one argument list does not
        // type-check in reasonable time.
        let message = Comment(
            rawValue: "Production views with no production reference: "
                + offenders.joined(separator: ", ")
                + ". Delete the view, wire it in, or — if it is deliberately "
                + "test-only — add it to allowedUnusedViews with a reason."
        )
        #expect(offenders.isEmpty, message)
    }

    @Test("Every allowlist entry names a declared production view")
    func allowlistStaysExact() throws {
        let sources = try Self.strippedProductionSources()
        let declared = Set(try Self.viewDeclarations(in: sources).map(\.name))

        let stale = Self.allowedUnusedViews.keys
            .filter { !declared.contains($0) }
            .sorted()

        // Same shape as above: a `Comment` from a plain String, with the
        // ternary hoisted out so the argument stays cheap to type-check.
        let suffix = stale.count == 1 ? "y" : "ies"
        let message = Comment(
            rawValue: "allowedUnusedViews names views that no longer exist: "
                + stale.joined(separator: ", ")
                + ". Remove the stale entr" + suffix
                + " so the list keeps meaning something."
        )
        #expect(stale.isEmpty, message)
    }

    // MARK: - The predicate on synthetic sources

    /// Routes every fixture through the same stripper as the real tree.
    ///
    /// Handing raw source straight to `unreferencedViews` makes comment and
    /// string-literal mentions count as references — the gap behind the five
    /// synthetic failures in CI #1584 — so the fixtures below never bypass
    /// the step `strippedProductionSources()` performs for the tree.
    private static func stripped(
        _ sources: [String: String]
    ) -> [String: String] {
        sources.mapValues(stripped)
    }

    @Test("A view no production file references is flagged")
    func deadViewIsFlagged() throws {
        let sources = Self.stripped([
            "Pine/Dead.swift": "struct DeadView: View {\n    var body: some View {\n        Text(verbatim: \"x\")\n    }\n}\n",
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == ["DeadView"])
    }

    @Test("A doc comment mentioning the view is not a reference")
    func commentOnlyMentionDoesNotCount() throws {
        // The exact `CommandOverlayView` trap: its own header comment and
        // its declaration were the only occurrences in the file, which a raw
        // text search reads as usage.
        let sources = Self.stripped([
            "Pine/Dead.swift": """
            //  DeadView.swift
            /// A view that is only mentioned, never used.
            struct DeadView: View {
                var body: some View { Text(verbatim: "x") }
            }
            """,
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == ["DeadView"])
    }

    @Test("A string literal naming the view is not a reference")
    func stringLiteralMentionDoesNotCount() throws {
        let sources = Self.stripped([
            "Pine/Dead.swift": "struct DeadView: View {\n    var body: some View { Text(verbatim: \"x\") }\n}\n",
            "Pine/Other.swift": "let label = \"DeadView\"\n",
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == ["DeadView"])
    }

    @Test("A reference from another production file counts")
    func crossFileReferenceCounts() throws {
        // The holder is an enum, not a View, so the fixture declares
        // exactly one view and the assertion isolates cross-file counting.
        // (A `Parent: View` holder would itself be unreferenced and land in
        // the result — the expectation mistake CI #1584 exposed.)
        let sources = Self.stripped([
            "Pine/Alive.swift": "struct AliveView: View {\n    var body: some View { Text(verbatim: \"x\") }\n}\n",
            "Pine/Host.swift": "enum Host {\n    static func make() -> AliveView { AliveView() }\n}\n",
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == [])
    }

    @Test("Use in the declaring file's own body counts")
    func sameFileUsageCounts() throws {
        // Same isolation: the consumer is an enum, not a View, so the only
        // declared view is the one used beside its declaration.
        let sources = Self.stripped([
            "Pine/Parent.swift": """
            struct ChildView: View {
                var body: some View { Text(verbatim: "x") }
            }

            enum PreviewFactory {
                static func make() -> ChildView { ChildView() }
            }
            """,
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == [])
    }

    @Test("Private views are exempt where public twins are flagged")
    func privateViewsAreExempt() throws {
        // One shape, two access levels: only the public twin may appear in
        // the result, so the exemption cannot pass vacuously.
        let sources = Self.stripped([
            "Pine/Island.swift": """
            private struct HelperView: View {
                var body: some View { Text(verbatim: "x") }
            }

            struct PublicDeadView: View {
                var body: some View { Text(verbatim: "x") }
            }
            """,
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == ["PublicDeadView"])
    }

    @Test("ViewModifier conformance is not a View")
    func viewModifierIsNotAView() throws {
        let sources = Self.stripped([
            "Pine/Modifier.swift": """
            struct UnusedModifier: ViewModifier {
                func body(content: Content) -> some View { content }
            }
            """,
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == [])
    }

    @Test("A generic View constraint is not a View conformance")
    func genericConstraintIsNotAConformance() throws {
        // A non-View container whose generic parameter happens to require
        // `View` must not be swept into the check by the word "View"
        // appearing in its angle brackets.
        let sources = Self.stripped([
            "Pine/Container.swift": """
            struct UnusedContainer<Content: View>: ViewModifier {
                func body(content: Content) -> some View { content }
            }
            """,
        ])

        let flagged = try Self.unreferencedViews(in: sources)

        #expect(flagged.map(\.name) == [])
    }

    @Test("Stripping keeps code and drops comments and literals")
    func strippingKeepsCode() {
        let source = """
        // line comment with struct Ghost: View
        let url = "https://ghost struct Ghost2: View"
        let code = Flag.on /* block comment
        spanning lines with struct Ghost3: View */
        """
        let stripped = Self.stripped(source)

        let words = stripped.split(whereSeparator: { $0 == " " || $0 == "\n" })
        #expect(words == ["let", "url", "=", "let", "code", "=", "Flag.on"])
        #expect(
            Self.referenceCount(of: "Ghost", in: stripped, upTo: 1) == 0,
            "Comment and literal mentions must be gone: \(stripped.debugDescription)"
        )
        #expect(
            Self.referenceCount(of: "Flag", in: stripped, upTo: 1) == 1,
            "Code after a same-line string literal must survive: \(stripped.debugDescription)"
        )
    }

    // MARK: - The scan

    /// Views deliberately kept without a production call site. Each entry
    /// is a follow-up decision recorded here, not a silent pass.
    private static let allowedUnusedViews: [String: String] = [
        "QuickTerminalSettingsView": """
            Standalone wrapper retained for previews and snapshot tests; the \
            consolidated Terminal settings pane embeds \
            QuickTerminalSettingsControls instead (#1583).
            """,
        "VerifiedDiffPreviewView": """
            Display-only component intentionally not wired to Agent History \
            yet (see its file header); rendered only by \
            VerifiedDiffPreviewSnapshotTests (#1583).
            """,
    ]

    private struct ViewDeclaration: Equatable {
        let name: String
        let path: String
        let isPrivate: Bool
    }

    /// Reads the production tree and returns comment/string-stripped
    /// sources keyed by path.
    private static func strippedProductionSources() throws -> [String: String] {
        var sources: [String: String] = [:]
        for url in try ProductionSourceScan.productionSwiftFileURLs() {
            let source = try String(contentsOf: url, encoding: .utf8)
            sources[url.path] = stripped(source)
        }
        return sources
    }

    /// Every `struct … : View` declared in the given stripped sources.
    private static func viewDeclarations(
        in strippedSources: [String: String]
    ) throws -> [ViewDeclaration] {
        let declarationPattern = try NSRegularExpression(
            pattern:
                "^[ \\t]*"
                + "((?:(?:@\\w+(?:\\([^)]*\\))?|private|fileprivate|internal|"
                + "public|open|final)[ \\t]+)*)"
                + "struct[ \\t]+([A-Za-z_]\\w*)",
            options: [.anchorsMatchLines]
        )

        var declarations: [ViewDeclaration] = []
        for (path, text) in strippedSources {
            let nsText = text as NSString
            let matches = declarationPattern.matches(
                in: text,
                range: NSRange(location: 0, length: nsText.length)
            )
            for match in matches {
                // Full match + the two capture groups (modifiers, name).
                guard match.numberOfRanges >= 3 else { continue }
                let modifiers = nsText.substring(with: match.range(at: 1))
                let nameRange = match.range(at: 2)
                let name = nsText.substring(with: nameRange)

                // The declaration header ends at the opening brace.
                let braceRange = nsText.range(
                    of: "{",
                    range: NSRange(
                        location: match.range.location,
                        length: nsText.length - match.range.location
                    )
                )
                guard braceRange.location != NSNotFound else { continue }
                // Bounded by the brace, so a `some View` in the body can
                // never read as the declaration's conformance.
                let afterNameRange = NSRange(
                    location: nameRange.location + nameRange.length,
                    length: braceRange.location
                        - (nameRange.location + nameRange.length)
                )
                guard afterNameRange.length >= 0,
                      viewConformance(
                        nsText.substring(with: afterNameRange)
                      ) else { continue }

                let isPrivate = referenceCount(of: "private", in: modifiers, upTo: 1) > 0
                    || referenceCount(of: "fileprivate", in: modifiers, upTo: 1) > 0
                declarations.append(
                    ViewDeclaration(name: name, path: path, isPrivate: isPrivate)
                )
            }
        }
        return declarations.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
    }

    /// Whether a declaration's remainder — everything after the type name,
    /// e.g. `<Content: View>: View {` — conforms to `View`.
    ///
    /// The generic parameter list is skipped first so a `Content: View`
    /// *constraint* can never masquerade as the conformance.
    private static func viewConformance(_ remainder: String) -> Bool {
        var clause = Substring(remainder)
        if clause.hasPrefix("<") {
            var depth = 0
            var index = clause.startIndex
            while index < clause.endIndex {
                let character = clause[index]
                if character == "<" {
                    depth += 1
                } else if character == ">" {
                    depth -= 1
                    if depth == 0 {
                        index = clause.index(after: index)
                        break
                    }
                }
                index = clause.index(after: index)
            }
            clause = clause[index...]
        }
        guard clause.hasPrefix(":") else { return false }
        return referenceCount(of: "View", in: String(clause.dropFirst()), upTo: 1) > 0
    }

    /// Declarations nothing in production references (allowlist aside).
    ///
    /// The input must already be stripped — `strippedProductionSources()` for
    /// the real tree, `stripped(_:)` for fixtures. On raw source, comment and
    /// string-literal mentions count as references (CI #1584).
    private static func unreferencedViews(
        in strippedSources: [String: String]
    ) throws -> [ViewDeclaration] {
        try viewDeclarations(in: strippedSources)
            .filter { !$0.isPrivate }
            .filter { declaration in
                let ownText = strippedSources[declaration.path] ?? ""
                let usedInOwnFile = referenceCount(
                    of: declaration.name,
                    in: ownText,
                    upTo: 2
                ) > 1
                if usedInOwnFile { return false }

                let usedElsewhere = strippedSources
                    .keys
                    .filter { $0 != declaration.path }
                    .contains { path in
                        referenceCount(
                            of: declaration.name,
                            in: strippedSources[path] ?? "",
                            upTo: 1
                        ) > 0
                    }
                return !usedElsewhere
            }
    }

    /// Occurrences of `name` in `text` standing on identifier boundaries,
    /// counted no further than `limit` — callers only ever need "any" or
    /// "more than one", and stopping early keeps the guard cheap on a tree
    /// of hundreds of files.
    private static func referenceCount(
        of name: String,
        in text: String,
        upTo limit: Int
    ) -> Int {
        guard !name.isEmpty, limit > 0 else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while count < limit,
              let found = text.range(of: name, range: searchRange) {
            if isIdentifierBoundary(before: found.lowerBound, in: text),
               isIdentifierBoundary(at: found.upperBound, in: text) {
                count += 1
            }
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    private static func isIdentifierBoundary(
        before index: String.Index,
        in text: String
    ) -> Bool {
        index == text.startIndex
            || !isIdentifierCharacter(text[text.index(before: index)])
    }

    private static func isIdentifierBoundary(
        at index: String.Index,
        in text: String
    ) -> Bool {
        index == text.endIndex || !isIdentifierCharacter(text[index])
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// Replaces comments and string literals with blanks so a textual
    /// reference scan cannot be satisfied by prose (`//  DeadView.swift` is
    /// not a use). Newlines survive so line-anchored patterns keep working.
    ///
    /// Handles the lexical forms that appear in Pine's sources: line
    /// comments, nesting block comments, double-quoted strings with
    /// backslash escapes, multiline `"""` strings, and single-`#` raw
    /// strings (`#"…"#`) — the `##`-delimiter variant does not appear in
    /// the tree. Interpolated content counts as string — no Pine view is
    /// referenced that way.
    private static func stripped(_ source: String) -> String {
        let characters = Array(source)
        var output = [Character]()
        output.reserveCapacity(characters.count)
        var index = 0

        func appendBlank(from start: Int, to end: Int) {
            for position in start..<min(end, characters.count) {
                output.append(characters[position] == "\n" ? "\n" : " ")
            }
        }

        while index < characters.count {
            // Line comment — blank to end of line, newline preserved.
            if characters[index] == "/", index + 1 < characters.count,
               characters[index + 1] == "/" {
                let start = index
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                appendBlank(from: start, to: index)
                continue
            }

            // Block comment — nests in Swift, newlines preserved.
            if characters[index] == "/", index + 1 < characters.count,
               characters[index + 1] == "*" {
                let start = index
                var depth = 0
                loop: while index < characters.count {
                    if index + 1 < characters.count, characters[index] == "/",
                       characters[index + 1] == "*" {
                        depth += 1
                        index += 2
                    } else if index + 1 < characters.count,
                              characters[index] == "*",
                              characters[index + 1] == "/" {
                        depth -= 1
                        index += 2
                        if depth == 0 { break loop }
                    } else {
                        index += 1
                    }
                }
                appendBlank(from: start, to: index)
                continue
            }

            // Raw string — `#` is lexical only directly before a quote;
            // `#if`, `#expect` and friends fall through untouched.
            if characters[index] == "#",
               index + 1 < characters.count, characters[index + 1] == "\"" {
                let start = index
                index += 2
                while index < characters.count,
                      !(characters[index] == "\""
                          && index + 1 < characters.count
                          && characters[index + 1] == "#") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                appendBlank(from: start, to: index)
                continue
            }

            // Multiline string.
            if characters[index] == "\"", index + 2 < characters.count,
               characters[index + 1] == "\"", characters[index + 2] == "\"" {
                let start = index
                index += 3
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += 2
                    } else if characters[index] == "\"",
                              index + 2 < characters.count,
                              characters[index + 1] == "\"",
                              characters[index + 2] == "\"" {
                        index += 3
                        break
                    } else {
                        index += 1
                    }
                }
                index = min(index, characters.count)
                appendBlank(from: start, to: index)
                continue
            }

            // Regular string with backslash escapes.
            if characters[index] == "\"" {
                let start = index
                index += 1
                while index < characters.count {
                    if characters[index] == "\\" {
                        index += 2
                    } else if characters[index] == "\"" {
                        index += 1
                        break
                    } else {
                        index += 1
                    }
                }
                index = min(index, characters.count)
                appendBlank(from: start, to: index)
                continue
            }

            output.append(characters[index])
            index += 1
        }
        return String(output)
    }
}
