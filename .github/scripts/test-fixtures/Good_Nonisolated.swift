// Good: class marked nonisolated — background queue is safe
import Foundation

nonisolated final class GoodWatcher {
    private let queue = DispatchQueue(label: "pine.watcher", qos: .utility)

    func start() {
        queue.async {
            print("watching")
        }
    }
}
