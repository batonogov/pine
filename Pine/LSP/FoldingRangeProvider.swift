//
//  FoldingRangeProvider.swift
//  Pine
//
//  Issue #1008, step 2 — LSP `textDocument/foldingRange` support.
//
//  Decodes LSP `FoldingRange` values and server capabilities from the
//  `initialize` result, and adapts the LSP folding request to the
//  ``FoldRangeProviding`` seam consumed by `FoldingCoordinator`.
//
//  All decoding is pure data work with no UI surface, so these types opt out
//  of the project-wide MainActor default isolation.
//

import Foundation
import os

// MARK: - Position encoding

/// The LSP general `positionEncoding` capability (3.17). Defaults to UTF-16
/// (the spec default) when the server omits it. Pine works in UTF-16 code
/// units throughout (`NSString`/`NSTextView`), so a UTF-8 server is flagged
/// for future conversion work.
nonisolated enum LSPPositionEncoding: Sendable, Equatable {
    case utf16
    case utf8
    case unknown

    /// Initialises from the raw `positionEncoding` string of an
    /// `initialize` result. Unknown values (including an empty string) map to
    /// the spec default, UTF-16.
    init(encoding raw: String?) {
        switch (raw ?? "").lowercased() {
        case "utf-16", "utf16":
            self = .utf16
        case "utf-8", "utf8":
            self = .utf8
        default:
            // Per the LSP spec, a server that does not advertise
            // positionEncoding defaults to UTF-16.
            self = .utf16
        }
    }
}

// MARK: - Server capabilities

/// The subset of server capabilities decoded from the `initialize` result that
/// structural providers care about. Captured once at handshake and consulted
/// per request so unsupported features short-circuit to the local fallback
/// without a round trip.
nonisolated struct LSPServerCapabilities: Sendable, Equatable {
    /// Whether the server advertises `textDocument/foldingRange`.
    let foldingRangeProvider: Bool
    /// Whether the server advertises `textDocument/documentSymbol` (step 4).
    let documentSymbolProvider: Bool
    /// The negotiated position encoding.
    let positionEncoding: LSPPositionEncoding

    init(json: Any) {
        let dict = (json as? [String: Any]) ?? [:]
        self.foldingRangeProvider = Self.capabilityFlag(dict["foldingRangeProvider"])
        self.documentSymbolProvider = Self.capabilityFlag(dict["documentSymbolProvider"])
        self.positionEncoding = LSPPositionEncoding(encoding: dict["positionEncoding"] as? String)
    }

    /// Empty capabilities (no server features). Used as the default before the
    /// handshake completes.
    static let none = LSPServerCapabilities(
        foldingRangeProvider: false,
        documentSymbolProvider: false,
        positionEncoding: .utf16
    )

    private init(
        foldingRangeProvider: Bool,
        documentSymbolProvider: Bool,
        positionEncoding: LSPPositionEncoding
    ) {
        self.foldingRangeProvider = foldingRangeProvider
        self.documentSymbolProvider = documentSymbolProvider
        self.positionEncoding = positionEncoding
    }

    /// An LSP capability may be a `Bool` (`true`) or an options object
    /// (`{...}`) — both mean "supported". `false` or absence means unsupported.
    private static func capabilityFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if value is [String: Any] { return true }
        return false
    }
}

// MARK: - FoldingRange value type

/// A single LSP `FoldingRange`. Lines and characters are 0-based per the spec.
/// `kind` is advisory (`"comment"`, `"imports"`, `"region"`, …).
nonisolated struct LSPFoldingRange: Equatable, Sendable {
    let startLine: Int
    let endLine: Int
    let startCharacter: Int?
    let endCharacter: Int?
    let kind: String?

    /// Initialises from one element of a `textDocument/foldingRange` result.
    /// Returns `nil` when the required `startLine`/`endLine` fields are
    /// missing or non-integer.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let startLine = dict["startLine"] as? Int,
              let endLine = dict["endLine"] as? Int else {
            return nil
        }
        self.startLine = startLine
        self.endLine = endLine
        self.startCharacter = dict["startCharacter"] as? Int
        self.endCharacter = dict["endCharacter"] as? Int
        self.kind = dict["kind"] as? String
    }

    init(
        startLine: Int,
        endLine: Int,
        startCharacter: Int? = nil,
        endCharacter: Int? = nil,
        kind: String? = nil
    ) {
        self.startLine = startLine
        self.endLine = endLine
        self.startCharacter = startCharacter
        self.endCharacter = endCharacter
        self.kind = kind
    }
}

// MARK: - LSP fold provider adapter

/// Adapts an LSP `textDocument/foldingRange` request to the
/// ``FoldRangeProviding`` seam. Queries through the injected LSP UI endpoint
/// closure and returns the decoded ranges, or `nil` to defer to the bracket
/// fallback on any absence/error.
///
/// The closure is supplied by `PaneLeafView` (mirroring the hover/definition
/// endpoint pattern) so this type stays free of project-state references and
/// is testable in isolation.
nonisolated final class LSPFoldProvider: FoldRangeProviding, @unchecked Sendable {

    /// Requests LSP folding ranges for a document. Returns the raw
    /// `LSPFoldingRange` list, or `nil` when LSP is disabled, the file has no
    /// server, or the request fails. `@Sendable` so it can be captured by the
    /// coordinator's `TaskGroup` race.
    private let requester: @Sendable (DocumentSnapshot) async -> [LSPFoldingRange]?

    init(requester: @Sendable @escaping (DocumentSnapshot) async -> [LSPFoldingRange]?) {
        self.requester = requester
    }

    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        // The endpoint no-ops when no server/handler is installed; capability
        // is resolved lazily by the request itself so we never short-circuit
        // a server that gained capability after a re-initialise.
        true
    }

    func foldRanges(for snapshot: DocumentSnapshot) async -> [FoldableRange]? {
        guard let lspRanges = await requester(snapshot), !lspRanges.isEmpty else {
            // Empty/absent LSP result → defer to the bracket fallback.
            return nil
        }
        // Normalise into Pine's model, validating against the snapshot text.
        // An all-invalid set also defers to the fallback.
        return FoldingCoordinator.normalize(lspRanges, snapshot: snapshot)
    }
}
