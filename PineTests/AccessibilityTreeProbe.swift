//
//  AccessibilityTreeProbe.swift
//  PineTests
//
//  Reads the accessibility tree a hosted SwiftUI view actually publishes.
//
//  Why not assert on the view code instead: a SwiftUI accessibility modifier
//  is a request, not a guarantee. macOS drops `.accessibilityValue` on an
//  element whose bridged role is `AXUnknown`, and drops `.accessibilityLabel`
//  on `Menu` entirely. A test that reads the modifier back — or that trusts
//  `XCUIElement.label`, which answers from the model — passes on exactly the
//  defect it was written to catch. The only honest source is the tree
//  VoiceOver reads, so that is what this probe walks.
//
//  Mechanics, matching the approach documented in
//  `RecoveryDialogEscapeSafetyTests`:
//
//  - SwiftUI does not put its accessibility elements in the view hierarchy.
//    Under an `NSHostingView` they are private objects reachable only through
//    the public `accessibilityChildren()` selector, so traversal goes through
//    KVC guarded by `responds(to:)` rather than through a Swift cast.
//  - The tree is built lazily and does not exist until an accessibility
//    client has asked for it. Querying our *own* pid is that ask, and needs
//    no TCC grant — the trust check gates inspecting other processes.
//
//  Nothing here is used by shipping code: production stays on public SwiftUI
//  and `NSAccessibility` API, and this file only reads what that produces.
//

import AppKit
import ApplicationServices
import SwiftUI
import Testing

@testable import Pine

/// The accessibility selectors a bridged element answers but does not declare
/// conformance to, so `as?` cannot reach them. Every call site guards with
/// `responds(to:)` first.
@MainActor
@objc private protocol AccessibilityActionPerforming {
    func accessibilityPerformPress() -> Bool
    func accessibilityPerformIncrement() -> Bool
    func accessibilityPerformDecrement() -> Bool
}

@MainActor
enum AccessibilityTreeProbe {

    /// A hosted view whose accessibility tree has been materialised.
    struct Hosted {
        let hostingView: NSView
        let window: NSWindow

        /// The root of the published tree.
        var root: NSObject { hostingView }

        func tearDown() {
            window.contentView = nil
            window.close()
        }
    }

    // MARK: - Hosting

    /// Hosts `content` off screen and returns it with a live accessibility
    /// tree. Borderless and parked far off screen so nothing flashes in front
    /// of whoever is running the suite; `isReleasedWhenClosed` is off because
    /// the AppKit default would free the window under the caller's reference.
    static func host(
        _ content: some View,
        size: NSSize,
        locale: String = "en"
    ) -> Hosted {
        let rootView = content.environment(\.locale, Locale(identifier: locale))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        // Ordered in, never made key. `NSApp.keyWindow` is process-wide state
        // that other suites assert against, and a probe window stealing it is
        // a way to fail somebody else's test from across the suite boundary.
        window.orderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        awaken()
        hostingView.layoutSubtreeIfNeeded()
        return Hosted(hostingView: hostingView, window: window)
    }

    private static var isAwake = false

    /// Makes AppKit materialise the accessibility tree for this process.
    ///
    /// The query itself is what switches accessibility on; until some client
    /// asks, a hosting view reports no accessibility children at all.
    ///
    /// Done once per process, not once per hosted view. Accessibility is a
    /// process-wide switch, and the run-loop spin that settles it holds the
    /// main actor — repeating it for every host starves neighbouring
    /// `@MainActor` suites that are waiting on short deadlines, which is a
    /// way to make somebody else's test flaky without touching their code.
    static func awaken() {
        guard !isAwake else { return }
        isAwake = true
        let application = AXUIElementCreateApplication(getpid())
        var children: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            application,
            kAXChildrenAttribute as CFString,
            &children
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    // MARK: - Traversal

    /// Every element in the published tree rooted at `root`, in visit order.
    static func elements(under root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [root]
        var visited = 0

        while !queue.isEmpty, visited < 10_000 {
            let current = queue.removeFirst()
            visited += 1
            found.append(current)
            for child in children(of: current) {
                queue.append(child)
            }
        }
        return found
    }

    static func children(of element: NSObject) -> [NSObject] {
        (attribute("accessibilityChildren", of: element) as? [Any] ?? [])
            .compactMap { $0 as? NSObject }
    }

    /// The first element published under `root` carrying `identifier`.
    static func element(
        under root: NSObject,
        identifier: String
    ) -> NSObject? {
        elements(under: root).first { self.identifier(of: $0) == identifier }
    }

    /// Every element published under `root` whose identifier starts with
    /// `prefix`, in tree order.
    static func elements(
        under root: NSObject,
        identifierPrefix prefix: String
    ) -> [NSObject] {
        elements(under: root).filter {
            self.identifier(of: $0)?.hasPrefix(prefix) == true
        }
    }

    /// Every non-empty label published under `root`, in tree order. Use this
    /// to assert that something a sighted user sees is *absent* from what
    /// VoiceOver hears.
    static func labels(under root: NSObject) -> [String] {
        elements(under: root).compactMap { element in
            let spoken = [label(of: element), value(of: element)]
                .compactMap { $0 }
                .joined(separator: " ")
            return spoken.isEmpty ? nil : spoken
        }
    }

    // MARK: - Attributes

    static func attribute(_ name: String, of element: NSObject) -> Any? {
        guard element.responds(to: NSSelectorFromString(name)) else {
            return nil
        }
        return element.value(forKey: name)
    }

    static func role(of element: NSObject) -> NSAccessibility.Role? {
        (attribute("accessibilityRole", of: element) as? String)
            .map(NSAccessibility.Role.init(rawValue:))
    }

    static func subrole(of element: NSObject) -> NSAccessibility.Subrole? {
        (attribute("accessibilitySubrole", of: element) as? String)
            .map(NSAccessibility.Subrole.init(rawValue:))
    }

    static func label(of element: NSObject) -> String? {
        attribute("accessibilityLabel", of: element) as? String
    }

    static func value(of element: NSObject) -> String? {
        switch attribute("accessibilityValue", of: element) {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func help(of element: NSObject) -> String? {
        attribute("accessibilityHelp", of: element) as? String
    }

    static func identifier(of element: NSObject) -> String? {
        let identifier = attribute("accessibilityIdentifier", of: element)
        guard let identifier = identifier as? String,
              !identifier.isEmpty else {
            return nil
        }
        return identifier
    }

    static func isSelected(of element: NSObject) -> Bool {
        (attribute("isAccessibilitySelected", of: element) as? Bool) ?? false
    }

    static func orientation(
        of element: NSObject
    ) -> NSAccessibilityOrientation? {
        guard let raw = attribute("accessibilityOrientation", of: element)
            as? Int else {
            return nil
        }
        return NSAccessibilityOrientation(rawValue: raw)
    }

    /// The rotor actions VoiceOver offers on this element.
    static func customActions(
        of element: NSObject
    ) -> [NSAccessibilityCustomAction] {
        attribute("accessibilityCustomActions", of: element)
            as? [NSAccessibilityCustomAction] ?? []
    }

    static func customActionNames(of element: NSObject) -> [String] {
        customActions(of: element).map(\.name)
    }

    // MARK: - Performing

    /// Performs the action VoiceOver's activate gesture sends. Returns `nil`
    /// when the element publishes no press at all, which is the difference
    /// between "VoiceOver can use this" and "VoiceOver can only read it".
    static func performPress(_ element: NSObject) -> Bool? {
        perform(element, selector: "accessibilityPerformPress") {
            $0.accessibilityPerformPress()
        }
    }

    static func performIncrement(_ element: NSObject) -> Bool? {
        perform(element, selector: "accessibilityPerformIncrement") {
            $0.accessibilityPerformIncrement()
        }
    }

    static func performDecrement(_ element: NSObject) -> Bool? {
        perform(element, selector: "accessibilityPerformDecrement") {
            $0.accessibilityPerformDecrement()
        }
    }

    /// Invokes the rotor action named `name`, or returns `nil` when the
    /// element does not offer one.
    static func performCustomAction(
        named name: String,
        on element: NSObject
    ) -> Bool? {
        guard let action = customActions(of: element)
            .first(where: { $0.name == name }) else {
            return nil
        }
        return action.handler?() ?? false
    }

    private static func perform(
        _ element: NSObject,
        selector: String,
        _ body: (AccessibilityActionPerforming) -> Bool
    ) -> Bool? {
        guard element.responds(to: NSSelectorFromString(selector)) else {
            return nil
        }
        return body(
            unsafeBitCast(element, to: AccessibilityActionPerforming.self)
        )
    }
}
