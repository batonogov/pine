//
//  SymbolParser.swift
//  Pine
//
//  Regex-based symbol extraction for symbol navigation (Cmd+Shift+R).
//

import Foundation

/// A symbol extracted from source code.
struct DocumentSymbol: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let kind: SymbolKind
    /// 1-based line number where the symbol is defined.
    let line: Int

    static func == (lhs: DocumentSymbol, rhs: DocumentSymbol) -> Bool {
        lhs.name == rhs.name && lhs.kind == rhs.kind && lhs.line == rhs.line
    }
}

/// The kind of a document symbol.
enum SymbolKind: String, CaseIterable, Comparable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case interface
    case function
    case property

    var displayName: String {
        switch self {
        case .class: "Class"
        case .struct: "Struct"
        case .enum: "Enum"
        case .protocol: "Protocol"
        case .interface: "Interface"
        case .function: "Function"
        case .property: "Property"
        }
    }

    var iconName: String {
        switch self {
        case .class: "c.square"
        case .struct: "s.square"
        case .enum: "e.square"
        case .protocol: "p.square"
        case .interface: "i.square"
        case .function: "f.square"
        case .property: "v.square"
        }
    }

    /// Sort order for grouping symbols by kind.
    static func < (lhs: SymbolKind, rhs: SymbolKind) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .class: 0
        case .struct: 1
        case .enum: 2
        case .protocol: 3
        case .interface: 4
        case .function: 5
        case .property: 6
        }
    }
}

/// Parses source code to extract symbols (functions, classes, structs, etc.).
/// Uses regex-based extraction and skips symbols inside comments and strings.
enum SymbolParser {

    // MARK: - Public API

    /// Extracts symbols from source code based on file extension.
    /// - Parameters:
    ///   - content: The source code text.
    ///   - fileExtension: The file extension (e.g. "swift", "py", "js").
    /// - Returns: An array of symbols sorted by line number.
    static func parse(content: String, fileExtension: String) -> [DocumentSymbol] {
        let rules = symbolRules(for: fileExtension.lowercased())
        guard !rules.isEmpty else { return [] }

        let excludedRanges = computeExcludedRanges(in: content, fileExtension: fileExtension)
        var symbols: [DocumentSymbol] = []

        for rule in rules {
            let nsContent = content as NSString
            let fullRange = NSRange(location: 0, length: nsContent.length)

            rule.regex.enumerateMatches(in: content, range: fullRange) { match, _, _ in
                guard let match else { return }

                // Skip matches inside comments or strings
                if isInsideExcludedRange(match.range, excludedRanges: excludedRanges) {
                    return
                }

                // Extract the symbol name from capture group 1
                guard match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound else { return }

                let nameRange = match.range(at: 1)
                let name = nsContent.substring(with: nameRange)
                let line = lineNumber(at: nameRange.location, in: content)

                symbols.append(DocumentSymbol(name: name, kind: rule.kind, line: line))
            }
        }

        symbols.sort { $0.line < $1.line }
        return symbols
    }

    /// Filters symbols using fuzzy subsequence matching (reuses QuickOpenProvider logic).
    static func filter(_ symbols: [DocumentSymbol], query: String) -> [DocumentSymbol] {
        guard !query.isEmpty else { return symbols }
        let queryLower = query.lowercased()
        return symbols.filter {
            QuickOpenProvider.isSubsequence(queryLower, of: $0.name.lowercased())
        }
    }

    // MARK: - Symbol Rules

    private struct SymbolRule {
        let regex: NSRegularExpression
        let kind: SymbolKind
    }

    /// Returns compiled regex rules for the given file extension.
    private static func symbolRules(for ext: String) -> [SymbolRule] {
        switch ext {
        case "swift":
            return swiftRules
        case "py", "pyw":
            return pythonRules
        case "js", "jsx", "mjs":
            return javascriptRules
        case "ts", "tsx":
            return typescriptRules
        case "go":
            return goRules
        case "rb":
            return rubyRules
        case "rs":
            return rustRules
        case "java", "kt", "kts":
            return javaKotlinRules
        default:
            return []
        }
    }

    // MARK: - Language-specific rules

    // swiftlint:disable force_try

    private static let swiftRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|internal|fileprivate|open|final|static|override|@\w+)\s+)*class\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|internal|fileprivate|open|final|static)\s+)*struct\s+(\w+)"#
            ),
            kind: .struct
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|internal|fileprivate|open)\s+)*enum\s+(\w+)"#
            ),
            kind: .enum
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|internal|fileprivate|open)\s+)*protocol\s+(\w+)"#
            ),
            kind: .protocol
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|internal|fileprivate|open|final|static|override|@\w+|mutating)\s+)*func\s+(\w+)"#
            ),
            kind: .function
        ),
    ]

    private static let pythonRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*class\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:async\s+)?def\s+(\w+)"#
            ),
            kind: .function
        ),
    ]

    private static let javascriptRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*class\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:async\s+)?function\s*\*?\s+(\w+)"#
            ),
            kind: .function
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>"#
            ),
            kind: .function
        ),
    ]

    private static let typescriptRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:export\s+)?(?:abstract\s+)?class\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:export\s+)?interface\s+(\w+)"#
            ),
            kind: .interface
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:export\s+)?enum\s+(\w+)"#
            ),
            kind: .enum
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:export\s+)?(?:async\s+)?function\s*\*?\s+(\w+)"#
            ),
            kind: .function
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\([^)]*\)\s*=>"#
            ),
            kind: .function
        ),
    ]

    private static let goRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*type\s+(\w+)\s+struct\b"#
            ),
            kind: .struct
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*type\s+(\w+)\s+interface\b"#
            ),
            kind: .interface
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*func\s+(?:\([^)]*\)\s+)?(\w+)"#
            ),
            kind: .function
        ),
    ]

    private static let rubyRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*class\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*module\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*def\s+(?:self\.)?(\w+[?!]?)"#
            ),
            kind: .function
        ),
    ]

    private static let rustRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)"#
            ),
            kind: .struct
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)"#
            ),
            kind: .enum
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)"#
            ),
            kind: .protocol
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)"#
            ),
            kind: .function
        ),
    ]

    private static let javaKotlinRules: [SymbolRule] = [
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|protected|abstract|final|static)\s+)*class\s+(\w+)"#
            ),
            kind: .class
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|protected)\s+)?interface\s+(\w+)"#
            ),
            kind: .interface
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|protected)\s+)?enum\s+(\w+)"#
            ),
            kind: .enum
        ),
        SymbolRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:^|\n)\s*(?:(?:public|private|protected|abstract|final|static|override|suspend)\s+)*fun\s+(\w+)"#
            ),
            kind: .function
        ),
    ]

    // swiftlint:enable force_try

    // MARK: - Comment/String Exclusion

    /// Computes ranges that should be excluded (comments and strings).
    private static func computeExcludedRanges(in content: String, fileExtension: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        // Determine comment patterns based on file extension
        let patterns: [String]
        switch fileExtension.lowercased() {
        case "swift", "js", "jsx", "ts", "tsx", "java", "kt", "kts", "go", "rs":
            patterns = [
                #"//[^\n]*"#,                   // single-line comment
                #"/\*[\s\S]*?\*/"#,             // block comment
                #""(?:[^"\\]|\\.)*""#,          // double-quoted string
                #"'(?:[^'\\]|\\.)*'"#,          // single-quoted string (JS/Java)
            ]
        case "py", "pyw":
            patterns = [
                #"#[^\n]*"#,                    // single-line comment
                #"\"\"\"[\s\S]*?\"\"\""#,       // triple-double-quoted string
                #"'''[\s\S]*?'''"#,             // triple-single-quoted string
                #""(?:[^"\\]|\\.)*""#,          // double-quoted string
                #"'(?:[^'\\]|\\.)*'"#,          // single-quoted string
            ]
        case "rb":
            patterns = [
                #"#[^\n]*"#,                    // single-line comment
                #""(?:[^"\\]|\\.)*""#,          // double-quoted string
                #"'(?:[^'\\]|\\.)*'"#,          // single-quoted string
            ]
        default:
            patterns = [
                #"//[^\n]*"#,
                #"/\*[\s\S]*?\*/"#,
                #""(?:[^"\\]|\\.)*""#,
            ]
        }

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: content, range: fullRange)
            for match in matches {
                ranges.append(match.range)
            }
        }

        return ranges
    }

    /// Checks if a match range falls inside any excluded range.
    private static func isInsideExcludedRange(_ range: NSRange, excludedRanges: [NSRange]) -> Bool {
        let matchStart = range.location
        for excluded in excludedRanges {
            let exStart = excluded.location
            let exEnd = exStart + excluded.length
            if matchStart >= exStart && matchStart < exEnd {
                return true
            }
        }
        return false
    }

    // MARK: - Line Number Computation

    /// Computes the 1-based line number for a character offset.
    static func lineNumber(at offset: Int, in content: String) -> Int {
        var line = 1
        var currentOffset = 0
        for char in content {
            if currentOffset >= offset { break }
            if char == "\n" { line += 1 }
            currentOffset += char.utf16.count
        }
        return line
    }
}
