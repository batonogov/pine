// Good: class explicitly @MainActor — developer intentionally chose this
import Foundation

@MainActor
@Observable
final class GoodExplicitActor {
    private let queue = DispatchQueue(label: "com.pine.explicit", qos: .utility)
}
