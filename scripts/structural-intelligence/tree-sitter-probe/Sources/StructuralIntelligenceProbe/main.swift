import Foundation
import SwiftTreeSitter
import TreeSitterSwift

private struct FixtureResult: Codable {
    let name: String
    let utf8Bytes: Int
    let utf16Units: Int
    let lines: Int
    let coldParseMilliseconds: Double
    let incrementalParseMilliseconds: Double
    let changedRangeCount: Int
    let nodeCount: Int
    let foldCandidateCount: Int
    let symbolCount: Int
    let maximumSymbolDepth: Int
    let rootHasError: Bool
    let timeoutCancelled: Bool
}

private enum ProbeError: Error, LocalizedError {
    case invalidArguments
    case unableToRead(String)
    case unableToSetLanguage
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "usage: StructuralIntelligenceProbe <name=path> [<name=path> ...]"
        case .unableToRead(let path):
            "unable to read fixture at \(path)"
        case .unableToSetLanguage:
            "unable to load the pinned Swift grammar"
        case .parseFailed(let name):
            "Tree-sitter failed to parse fixture \(name)"
        }
    }
}

private let declarationTypes: Set<String> = [
    "class_declaration",
    "enum_declaration",
    "extension_declaration",
    "function_declaration",
    "protocol_declaration",
    "struct_declaration",
]

private let foldTypes: Set<String> = [
    "class_body",
    "enum_class_body",
    "function_body",
    "protocol_body",
    "statements",
    "switch_entry",
]

private func elapsedMilliseconds(_ operation: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try operation()
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    return Double(elapsed) / 1_000_000
}

private func collectMetrics(
    from node: Node,
    symbolDepth: Int = 0
) -> (nodes: Int, folds: Int, symbols: Int, maximumDepth: Int) {
    let type = node.nodeType ?? ""
    let isDeclaration = declarationTypes.contains(type)
    let nextDepth = symbolDepth + (isDeclaration ? 1 : 0)

    var result = (
        nodes: 1,
        folds: foldTypes.contains(type)
            && node.pointRange.lowerBound.row < node.pointRange.upperBound.row ? 1 : 0,
        symbols: isDeclaration ? 1 : 0,
        maximumDepth: isDeclaration ? nextDepth : symbolDepth
    )

    for index in 0..<node.namedChildCount {
        guard let child = node.namedChild(at: index) else { continue }
        let childMetrics = collectMetrics(from: child, symbolDepth: nextDepth)
        result.nodes += childMetrics.nodes
        result.folds += childMetrics.folds
        result.symbols += childMetrics.symbols
        result.maximumDepth = max(result.maximumDepth, childMetrics.maximumDepth)
    }

    return result
}

private func point(atUTF16Offset offset: Int, in source: NSString) -> Point {
    let clampedOffset = max(0, min(offset, source.length))
    let prefix = source.substring(to: clampedOffset) as NSString
    let row = prefix.components(separatedBy: "\n").count - 1
    let lastNewline = prefix.range(
        of: "\n",
        options: .backwards
    )
    let lineStart = lastNewline.location == NSNotFound
        ? 0
        : NSMaxRange(lastNewline)
    // Tree-sitter Point columns are bytes even when the input encoding is
    // UTF-16LE, so each Foundation UTF-16 code unit occupies two columns.
    return Point(row: row, column: (clampedOffset - lineStart) * 2)
}

private func measureFixture(
    name: String,
    source: String,
    parser: Parser
) throws -> FixtureResult {
    var initialTree: MutableTree?
    let coldMilliseconds = try elapsedMilliseconds {
        initialTree = parser.parse(source)
        guard initialTree != nil else { throw ProbeError.parseFailed(name) }
    }
    guard let initialTree, let root = initialTree.rootNode else {
        throw ProbeError.parseFailed(name)
    }
    // Nodes are invalid after their tree is edited. Capture all full-parse
    // structure before applying the incremental edit below.
    let metrics = collectMetrics(from: root)
    let rootHasError = root.hasError

    let marker = "\n// incremental edit 🌲\n"
    let sourceNSString = source as NSString
    let insertionOffset = sourceNSString.length
    let editedSource = source + marker
    let insertionPoint = point(
        atUTF16Offset: insertionOffset,
        in: sourceNSString
    )
    let newEnd = insertionOffset + (marker as NSString).length
    let editedNSString = editedSource as NSString
    let newEndPoint = point(atUTF16Offset: newEnd, in: editedNSString)
    let edit = InputEdit(
        startByte: insertionOffset * 2,
        oldEndByte: insertionOffset * 2,
        newEndByte: newEnd * 2,
        startPoint: insertionPoint,
        oldEndPoint: insertionPoint,
        newEndPoint: newEndPoint
    )
    initialTree.edit(edit)

    var updatedTree: MutableTree?
    let incrementalMilliseconds = try elapsedMilliseconds {
        updatedTree = parser.parse(tree: initialTree, string: editedSource)
        guard updatedTree != nil else { throw ProbeError.parseFailed(name) }
    }
    guard let updatedTree else { throw ProbeError.parseFailed(name) }

    let changedRanges = initialTree.changedRanges(from: updatedTree)

    parser.timeout = 0.000_001
    let cancelledTree = parser.parse(source)
    let timeoutCancelled = cancelledTree == nil
    parser.reset()
    parser.timeout = 0

    return FixtureResult(
        name: name,
        utf8Bytes: source.utf8.count,
        utf16Units: source.utf16.count,
        lines: source.components(separatedBy: "\n").count,
        coldParseMilliseconds: coldMilliseconds,
        incrementalParseMilliseconds: incrementalMilliseconds,
        changedRangeCount: changedRanges.count,
        nodeCount: metrics.nodes,
        foldCandidateCount: metrics.folds,
        symbolCount: metrics.symbols,
        maximumSymbolDepth: metrics.maximumDepth,
        rootHasError: rootHasError,
        timeoutCancelled: timeoutCancelled
    )
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { throw ProbeError.invalidArguments }

    let parser = Parser()
    do {
        try parser.setLanguage(Language(language: tree_sitter_swift()))
    } catch {
        throw ProbeError.unableToSetLanguage
    }

    var results: [FixtureResult] = []
    for argument in arguments {
        let parts = argument.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { throw ProbeError.invalidArguments }
        let name = String(parts[0])
        let path = String(parts[1])
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ProbeError.unableToRead(path)
        }
        results.append(try measureFixture(name: name, source: source, parser: parser))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(results)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
