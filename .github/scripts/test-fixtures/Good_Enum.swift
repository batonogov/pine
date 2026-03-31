// Good: enum with static methods — no stored state, background queue is safe
import Foundation

enum GoodEnumFetcher {
    static func fetch() {
        DispatchQueue.global().async {
            print("enum static method")
        }
    }
}
