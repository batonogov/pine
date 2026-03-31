// Good: only uses DispatchQueue.main — no background work
import Foundation

final class GoodMainOnly {
    func refresh() {
        DispatchQueue.main.async {
            print("on main")
        }
    }
}
