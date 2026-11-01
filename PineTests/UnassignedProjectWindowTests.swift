import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Unassigned Project Window")
@MainActor
struct UnassignedProjectWindowTests {
    @Test("a nil-URL scene mounts a view so its recovery task can run")
    func recoveryViewIsNotEmpty() {
        let host = NSHostingView(rootView: UnassignedProjectWindowView())
        #expect(host.fittingSize.width > 0)
        #expect(host.fittingSize.height > 0)
    }

    @Test("the fallback scene type has a launch-stable name")
    func sceneTypeNameIsStable() {
        #expect(_typeName(UnassignedProjectWindowView.self) == "Pine.UnassignedProjectWindowView")
    }
}
