import Foundation

struct Catalog {
    let title: String

    enum Status {
        case draft
        case published
    }

    func render(items: [String]) -> String {
        items.map { item in
            "\(title): \(item)"
        }
        .joined(separator: "\n")
    }
}

func greeting(for name: String) -> String {
    let emoji = "🌲"
    let localized = "你好, \(name)"
    return "\(emoji) \(localized)"
}
