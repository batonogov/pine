//
//  BracketProvider.swift
//  Pine
//
//  Snapshot adapter for Pine's bounded bracket matcher (#1008).
//

import Foundation

/// The universal production bracket provider.
///
/// It intentionally wraps the existing bounded scanner rather than adding a
/// parser dependency. Syntax highlighting supplies comment/string skip ranges
/// captured for the same immutable text revision.
nonisolated struct BoundedBracketProvider: BracketProviding {
    func canProvide(for snapshot: DocumentSnapshot) -> Bool {
        true
    }

    func highlight(
        for snapshot: BracketSnapshot
    ) -> BracketHighlightResult? {
        guard canProvide(for: snapshot.document) else { return nil }
        let length = (snapshot.document.text as NSString).length
        guard snapshot.cursorPosition >= 0,
              snapshot.cursorPosition <= length else {
            return nil
        }
        return BracketMatcher.findHighlight(
            in: snapshot.document.text,
            cursorPosition: snapshot.cursorPosition,
            skipRanges: snapshot.skipRanges
        )
    }
}
