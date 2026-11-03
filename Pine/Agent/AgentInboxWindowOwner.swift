import AppKit

/// Resolves only explicit AppKit ownership, never the unrelated key/main window.
/// Full-screen and overflow toolbars can move an item's view to another window
/// without giving that window the project's CloseDelegate.
@MainActor
enum AgentInboxWindowOwner {
    static func resolve(_ window: NSWindow?, among windows: [NSWindow]) -> NSWindow? {
        var candidate = window
        var visited = Set<ObjectIdentifier>()
        while let current = candidate, visited.insert(ObjectIdentifier(current)).inserted {
            if let parent = current.parent {
                candidate = parent
                continue
            }
            if let owner = windows.first(where: { owner in
                owner !== current && owner.toolbar?.items.contains(where: { item in
                    item.view?.window === current
                }) == true
            }) {
                candidate = owner
                continue
            }
            return current
        }
        return nil
    }
}
