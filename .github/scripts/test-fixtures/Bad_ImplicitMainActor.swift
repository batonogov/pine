// Bad: no isolation annotation — implicitly @MainActor with background queue
import Foundation

@Observable
final class BadValidator {
    private let queue = DispatchQueue(label: "com.pine.bad-validator", qos: .utility)

    func validate() {
        queue.async {
            print("validating on background")
        }
    }
}
