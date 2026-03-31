// Bad: uses DispatchQueue.global() without nonisolated
import Foundation

final class BadFetcher {
    func fetchData() {
        DispatchQueue.global().async {
            print("fetching on background")
        }
    }
}
