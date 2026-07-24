//
//  ConcurrentFileNodeBufferTests.swift
//  PineTests
//
//  Regression coverage for the thread-safe result buffer used by
//  `WorkspaceManager.loadTopLevelInParallel`.
//

import Foundation
import Testing

@testable import Pine

@Suite("Concurrent File Node Buffer Tests")
struct ConcurrentFileNodeBufferTests {

    @Test("Indexed concurrent writes land at correct positions")
    func indexedWritesRoundTrip() {
        let count = 256
        let buffer = ConcurrentFileNodeBuffer(count: count)

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let node = FileNode(
                url: URL(fileURLWithPath: "/tmp/concurrent-node-\(index).swift")
            )
            buffer.store(node, at: index)
        }

        let nodes = buffer.compacted()
        #expect(nodes.count == count)
        #expect(nodes.map(\.name) == (0..<count).map { "concurrent-node-\($0).swift" })
    }

    @Test("Storage releases reference elements")
    func releasesReferenceElements() {
        weak var weakNode: FileNode?

        do {
            let buffer = ConcurrentFileNodeBuffer(count: 1)
            let node = FileNode(
                url: URL(fileURLWithPath: "/tmp/concurrent-node-lifetime.swift")
            )
            weakNode = node
            buffer.store(node, at: 0)
            #expect(weakNode != nil)
        }

        #expect(weakNode == nil)
    }
}
