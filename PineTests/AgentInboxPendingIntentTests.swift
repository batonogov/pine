import Testing

@testable import Pine

struct AgentInboxPendingIntentTests {
    @Test("a second toggle cancels presentation before the anchor mounts")
    func secondToggleCancelsPendingOpen() {
        var state = AgentInboxPopoverPresentationState()
        _ = state.toggleButtonToggled(bindingIsPresented: false, isPopoverShown: false,
                                      dismissedBySameGesture: false)
        let close = state.toggleButtonToggled(bindingIsPresented: true, isPopoverShown: false,
                                             dismissedBySameGesture: false)
        #expect(close.effect == .close)
        #expect(close.bindingIsPresented == false)
        #expect(!state.hasUnservedRouterRequest)
        #expect(state.anchorWindowDidChange(bindingIsPresented: false, isPopoverShown: false).effect == .inert)
    }
}
