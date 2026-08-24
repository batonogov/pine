//
//  LocalizationCatalogCompletenessTests.swift
//  PineTests
//

import Foundation
import Testing

@Suite("Localization catalog completeness")
struct LocalizationCatalogCompletenessTests {
    private struct SourceReference: Hashable {
        let path: String
        let line: Int
        let key: String
    }

    private static let supportedLocales = Set([
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ])

    private static let formatOnlyKeys = Set([
        "",
        " ●",
        "…",
        "%@%@%@",
        "%lld",
        "1–%lld",
    ])

    @Test("Every user-facing entry covers all supported locales")
    func everyTranslatableEntryIsComplete() throws {
        let strings = try loadCatalog()

        for key in strings.keys.sorted() {
            let entry = try #require(strings[key] as? [String: Any])
            if entry["shouldTranslate"] as? Bool == false {
                continue
            }

            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key.debugDescription)"
            )
            #expect(
                Set(localizations.keys) == Self.supportedLocales,
                "Incomplete locales for \(key.debugDescription)"
            )

            for locale in Self.supportedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any]
                )
                let units = stringUnitValues(in: localization)
                #expect(
                    !units.isEmpty,
                    "Missing string unit for \(key) [\(locale)]"
                )
                for value in units {
                    #expect(
                        !value.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty,
                        "Empty translation for \(key) [\(locale)]"
                    )
                }
            }
        }
    }

    @Test("Format-only entries are explicitly opted out")
    func formatOnlyEntriesAreExplicit() throws {
        let strings = try loadCatalog()
        let optedOut: Set<String> = Set(strings.compactMap { key, rawEntry in
            guard
                let entry = rawEntry as? [String: Any],
                entry["shouldTranslate"] as? Bool == false
            else {
                return nil
            }
            return key
        })

        #expect(optedOut == Self.formatOnlyKeys)
    }

    @Test("Format placeholders match across locales")
    func placeholdersMatchEnglish() throws {
        let strings = try loadCatalog()

        for key in strings.keys.sorted() {
            let entry = try #require(strings[key] as? [String: Any])
            guard entry["shouldTranslate"] as? Bool != false else {
                continue
            }
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            let english = try #require(
                localizations["en"] as? [String: Any]
            )
            let expected = placeholderSignatures(in: english)

            for locale in Self.supportedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any]
                )
                #expect(
                    placeholderSignatures(in: localization) == expected,
                    "Placeholder mismatch for \(key) [\(locale)]"
                )
            }
        }
    }

    @Test("Static source localization keys exist in the catalog")
    func staticSourceKeysExistInCatalog() throws {
        let projectRoot = Self.projectRoot()
        let catalogKeys = Set(try loadCatalog().keys)
        let references = try sourceReferences(projectRoot: projectRoot)
        let missing = references.filter {
            !catalogContains(sourceKey: $0.key, catalogKeys: catalogKeys)
        }

        #expect(
            missing.isEmpty,
            """
            Missing localization catalog entries:
            \(missing.map {
                "\($0.path):\($0.line): \($0.key)"
            }.joined(separator: "\n"))
            """
        )
    }

    private func loadCatalog() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.projectRoot().appendingPathComponent(
            "Pine/Localizable.xcstrings"
        ))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(root["strings"] as? [String: Any])
    }

    private static func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceReferences(
        projectRoot: URL
    ) throws -> [SourceReference] {
        // Not a local enumeration: `.skipsHiddenFiles` used to live here, and
        // every file in an agent worktree under `.claude/worktrees/…` carries
        // the `UF_HIDDEN` flag, so this guard scanned zero files and passed
        // vacuously wherever it was actually run (#1508).
        // `ProductionSourceScan` also refuses to return an empty list, so a
        // completeness test can never again pass by scanning nothing.
        let sourceURLs = try ProductionSourceScan.swiftFileURLs(
            under: projectRoot.appendingPathComponent("Pine")
        )

        let localizedKeyExpression = try NSRegularExpression(
            pattern:
                #"LocalizedStringKey\s*=\s*"((?:\\.|[^"\\])*)""#,
            options: [.dotMatchesLineSeparators]
        )
        let localizedStringExpression = try NSRegularExpression(
            pattern:
                #"String\s*\(\s*localized:\s*"((?:\\.|[^"\\])*)""#,
            options: [.dotMatchesLineSeparators]
        )
        let stringLiteralExpression = try NSRegularExpression(
            pattern: #""((?:\\.|[^"\\])*)""#,
            options: [.dotMatchesLineSeparators]
        )
        let stableKeyExpression = try NSRegularExpression(
            pattern:
                #"^[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_-]+)+"#
        )

        var references = Set<SourceReference>()
        for url in sourceURLs {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(
                of: projectRoot.path + "/",
                with: ""
            )
            addReferences(
                from: source,
                path: relativePath,
                expression: localizedKeyExpression,
                to: &references
            )
            addReferences(
                from: source,
                path: relativePath,
                expression: localizedStringExpression,
                to: &references
            )

            // `Strings.swift` also centralizes keys passed through Pine's
            // explicit-locale helpers. They are plain string arguments rather
            // than `String(localized:)`, so include every dot-separated key
            // literal from that file.
            guard url.lastPathComponent == "Strings.swift" else {
                continue
            }
            addReferences(
                from: source,
                path: relativePath,
                expression: stringLiteralExpression,
                filter: { literal in
                    let range = NSRange(
                        literal.startIndex...,
                        in: literal
                    )
                    return stableKeyExpression.firstMatch(
                        in: literal,
                        range: range
                    ) != nil
                },
                to: &references
            )
        }

        return references.sorted {
            ($0.path, $0.line, $0.key) < ($1.path, $1.line, $1.key)
        }
    }

    private func addReferences(
        from source: String,
        path: String,
        expression: NSRegularExpression,
        filter: (String) -> Bool = { _ in true },
        to references: inout Set<SourceReference>
    ) {
        let sourceRange = NSRange(source.startIndex..., in: source)
        for match in expression.matches(in: source, range: sourceRange) {
            guard
                let keyRange = Range(match.range(at: 1), in: source)
            else {
                continue
            }
            let key = decodeUnicodeEscapes(String(source[keyRange]))
            guard filter(key) else { continue }

            let prefix = (source as NSString).substring(
                to: match.range.location
            )
            let line = prefix.reduce(into: 1) { count, character in
                if character == "\n" {
                    count += 1
                }
            }
            references.insert(SourceReference(
                path: path,
                line: line,
                key: key
            ))
        }
    }

    private func decodeUnicodeEscapes(_ source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"\\u\{([0-9A-Fa-f]+)\}"#
        ) else {
            return source
        }

        var decoded = source
        while let match = expression.firstMatch(
            in: decoded,
            range: NSRange(decoded.startIndex..., in: decoded)
        ),
        let matchRange = Range(match.range, in: decoded),
        let scalarRange = Range(match.range(at: 1), in: decoded),
        let value = UInt32(decoded[scalarRange], radix: 16),
        let scalar = UnicodeScalar(value) {
            decoded.replaceSubrange(
                matchRange,
                with: String(Character(scalar))
            )
        }
        return decoded
    }

    private func catalogContains(
        sourceKey: String,
        catalogKeys: Set<String>
    ) -> Bool {
        let interpolationExpression = try? NSRegularExpression(
            pattern: #"\\\([^)]*\)"#
        )
        let sourceRange = NSRange(sourceKey.startIndex..., in: sourceKey)
        let matches = interpolationExpression?.matches(
            in: sourceKey,
            range: sourceRange
        ) ?? []

        var pattern = "^"
        var cursor = sourceKey.startIndex
        for match in matches {
            guard let range = Range(match.range, in: sourceKey) else {
                continue
            }
            pattern += NSRegularExpression.escapedPattern(
                for: String(sourceKey[cursor..<range.lowerBound])
            )
            pattern += #"%([0-9]+\$)?(?:@|lld)"#
            cursor = range.upperBound
        }
        pattern += NSRegularExpression.escapedPattern(
            for: String(sourceKey[cursor...])
        )
        pattern += "$"

        guard let expression = try? NSRegularExpression(pattern: pattern)
        else {
            return false
        }
        return catalogKeys.contains { key in
            expression.firstMatch(
                in: key,
                range: NSRange(key.startIndex..., in: key)
            ) != nil
        }
    }

    private func stringUnitValues(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var values: [String] = []
            if let unit = dictionary["stringUnit"] as? [String: Any],
               let text = unit["value"] as? String {
                values.append(text)
            }
            for (key, child) in dictionary where key != "stringUnit" {
                values.append(contentsOf: stringUnitValues(in: child))
            }
            return values
        }
        if let array = value as? [Any] {
            return array.flatMap { stringUnitValues(in: $0) }
        }
        return []
    }

    private func placeholderSignatures(
        in localization: [String: Any]
    ) -> Set<[String]> {
        Set(stringUnitValues(in: localization).map(placeholderSignature))
    }

    private func placeholderSignature(in value: String) -> [String] {
        let expression = try? NSRegularExpression(
            pattern: #"%#@[A-Za-z0-9_.-]+@|%([0-9]+\$)?(?:@|lld)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        var implicitPosition = 1
        let tokens = expression?.matches(
            in: value,
            range: range
        ).compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: value) else {
                return nil
            }
            let token = String(value[matchRange])
            if token.hasPrefix("%#@") {
                return token
            }

            let conversion = token.hasSuffix("lld") ? "lld" : "@"
            if match.numberOfRanges > 1,
               let positionRange = Range(match.range(at: 1), in: value) {
                let position = String(
                    value[positionRange].dropLast()
                )
                return "\(position)$\(conversion)"
            }

            defer { implicitPosition += 1 }
            return "\(implicitPosition)$\(conversion)"
        } ?? []
        return tokens.sorted()
    }
}
