import Testing
import Foundation
@testable import Pine

@Suite("Pane layout persistence")
struct PaneNodeTests {
    @Test func legacyTreeQueriesAndCodableRoundTrip() throws {
        let editor = PaneID()
        let terminal = PaneID()
        let node = PaneNode.split(
            .vertical,
            first: .leaf(editor, .editor),
            second: .leaf(terminal, .terminal),
            ratio: 0.65
        )
        #expect(node.leafIDs == [editor, terminal])
        #expect(node.firstLeafID == editor)
        #expect(node.content(for: terminal) == .terminal)
        #expect(node.leafCount == 2)
        #expect(node.depth == 2)

        let data = try JSONEncoder().encode(node)
        #expect(try JSONDecoder().decode(PaneNode.self, from: data) == node)
    }
}
