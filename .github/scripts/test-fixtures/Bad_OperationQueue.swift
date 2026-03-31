// Bad: uses OperationQueue without nonisolated
import Foundation

final class BadHighlighter {
    private let highlightQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
}
