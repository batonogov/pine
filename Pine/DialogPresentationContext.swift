//
//  DialogPresentationContext.swift
//  Pine
//
//  Window-owned, queued presentation for alerts and file panels.
//

import AppKit

/// Serializes every native dialog belonging to one window.
///
/// AppKit does not permit two sheets on the same window. More importantly,
/// resolving the owner lazily from `NSApp.keyWindow` can move a confirmation
/// to a different project while the request is suspended. This coordinator
/// captures its owner weakly, queues requests in FIFO order, and resolves
/// every pending request exactly once with `.abort` if the owner closes.
@MainActor
final class WindowDialogCoordinator {
    typealias Start = (
        _ owner: NSWindow,
        _ completion: @escaping (NSApplication.ModalResponse) -> Void
    ) -> Void
    typealias Cancel = (_ owner: NSWindow) -> Void

    private final class Request {
        let id: UUID
        let start: Start
        let cancel: Cancel
        var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
        private(set) var isResolved = false

        init(id: UUID, start: @escaping Start, cancel: @escaping Cancel) {
            self.id = id
            self.start = start
            self.cancel = cancel
        }

        func resolve(_ response: NSApplication.ModalResponse) {
            guard !isResolved else { return }
            isResolved = true
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: response)
        }
    }

    private weak var ownerWindow: NSWindow?
    private var queuedRequests: [Request] = []
    private var activeRequest: Request?
    private var closeObserver: Any?
    private var sheetEndObserver: Any?
    private var activationObserver: Any?
    private let notificationCenter: NotificationCenter
    private let onOwnerClose: () -> Void
    private(set) var isOwnerClosed = false

    var pendingRequestCount: Int {
        queuedRequests.count + (activeRequest == nil ? 0 : 1)
    }

    init(
        ownerWindow: NSWindow,
        notificationCenter: NotificationCenter = .default,
        onOwnerClose: @escaping () -> Void = {}
    ) {
        self.ownerWindow = ownerWindow
        self.notificationCenter = notificationCenter
        self.onOwnerClose = onOwnerClose
        closeObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let senderIdentifier = (notification.object as AnyObject?)
                .map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      senderIdentifier == self.ownerWindow.map(ObjectIdentifier.init) else {
                    return
                }
                self.ownerDidClose()
            }
        }
        sheetEndObserver = notificationCenter.addObserver(
            forName: NSWindow.didEndSheetNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let senderIdentifier = (notification.object as AnyObject?)
                .map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      senderIdentifier == self.ownerWindow.map(ObjectIdentifier.init) else {
                    return
                }
                self.presentNextIfPossible()
            }
        }
        activationObserver = notificationCenter.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let senderIdentifier = (notification.object as AnyObject?)
                .map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self,
                      senderIdentifier == self.ownerWindow.map(ObjectIdentifier.init) else {
                    return
                }
                self.presentNextIfPossible()
            }
        }
    }

    isolated deinit {
        if let closeObserver {
            notificationCenter.removeObserver(closeObserver)
        }
        if let sheetEndObserver {
            notificationCenter.removeObserver(sheetEndObserver)
        }
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Enqueues a native sheet. Missing/closed owners fail closed with
    /// `.abort`; a dialog is never promoted to an application-modal window.
    func present(
        start: @escaping Start,
        cancel: @escaping Cancel
    ) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled else { return .abort }
        guard !isOwnerClosed else { return .abort }
        guard ownerWindow != nil else {
            ownerDidClose()
            return .abort
        }

        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let request = Request(
                    id: requestID,
                    start: start,
                    cancel: cancel
                )
                request.continuation = continuation
                queuedRequests.append(request)
                presentNextIfPossible()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: requestID)
            }
        }
    }

    /// Public to the module so lifecycle tests can exercise the exact
    /// once-only cancellation path without actually closing an NSWindow.
    func ownerDidClose() {
        guard !isOwnerClosed else { return }
        isOwnerClosed = true

        if let activeRequest {
            self.activeRequest = nil
            if let ownerWindow {
                activeRequest.cancel(ownerWindow)
            }
            activeRequest.resolve(.abort)
        }

        let queued = queuedRequests
        queuedRequests.removeAll()
        for request in queued {
            request.resolve(.abort)
        }
        onOwnerClose()
    }

    private func cancelRequest(id: UUID) {
        if let activeRequest, activeRequest.id == id {
            self.activeRequest = nil
            if let ownerWindow {
                activeRequest.cancel(ownerWindow)
            }
            activeRequest.resolve(.abort)
            presentNextIfPossible()
            return
        }
        guard let index = queuedRequests.firstIndex(where: { $0.id == id }) else {
            return
        }
        let request = queuedRequests.remove(at: index)
        request.resolve(.abort)
    }

    private func presentNextIfPossible() {
        guard activeRequest == nil, !queuedRequests.isEmpty else { return }
        guard let ownerWindow, !isOwnerClosed else {
            ownerDidClose()
            return
        }
        // SwiftUI and framework-owned sheets do not enter this coordinator.
        // Wait for them to finish instead of asking AppKit to attach a second
        // sheet to the same window.
        guard ownerWindow.attachedSheet == nil else { return }

        let request = queuedRequests.removeFirst()
        activeRequest = request
        request.start(ownerWindow) { [weak self, weak request] response in
            Task { @MainActor in
                guard let self, let request else { return }
                self.finish(request, response: response)
            }
        }
    }

    private func finish(
        _ request: Request,
        response: NSApplication.ModalResponse
    ) {
        request.resolve(response)
        if activeRequest === request {
            activeRequest = nil
        }
        guard !isOwnerClosed else { return }
        // Let AppKit finish detaching the just-ended sheet before consulting
        // `attachedSheet` for the next request. Some panel completions arrive
        // one run-loop turn before that relationship is cleared.
        Task { @MainActor [weak self] in
            self?.presentNextIfPossible()
        }
    }
}

/// Captured presentation authority for one initiating window.
///
/// The context strongly retains only the coordinator. The coordinator keeps
/// the window weak, so an asynchronous request cannot extend the window's
/// lifetime or attach itself to whatever window later becomes key.
@MainActor
struct DialogPresentationContext {
    fileprivate let coordinator: WindowDialogCoordinator?

    init(window: NSWindow?) {
        coordinator = window.map { DialogPresenter.coordinator(for: $0) }
    }

    fileprivate init(coordinator: WindowDialogCoordinator?) {
        self.coordinator = coordinator
    }

    /// A deliberately unavailable owner. Presentation against this context
    /// returns `.abort` and performs no UI.
    static var unscoped: DialogPresentationContext {
        DialogPresentationContext(coordinator: nil)
    }

    var nsWindow: NSWindow? {
        coordinator?.ownerWindowForPresentation
    }

    func present(
        start: @escaping WindowDialogCoordinator.Start,
        cancel: @escaping WindowDialogCoordinator.Cancel
    ) async -> NSApplication.ModalResponse {
        guard let coordinator else { return .abort }
        return await coordinator.present(start: start, cancel: cancel)
    }
}

private extension WindowDialogCoordinator {
    var ownerWindowForPresentation: NSWindow? {
        guard !isOwnerClosed else { return nil }
        guard let ownerWindow else {
            ownerDidClose()
            return nil
        }
        return ownerWindow
    }
}

@MainActor
enum DialogPresenter {
    private final class ProjectBinding {
        weak var window: NSWindow?
        weak var projectManager: ProjectManager?

        init(window: NSWindow, projectManager: ProjectManager) {
            self.window = window
            self.projectManager = projectManager
        }
    }

    private static var coordinators: [ObjectIdentifier: WindowDialogCoordinator] = [:]
    private static var projectBindings: [ObjectIdentifier: ProjectBinding] = [:]

    static func coordinator(for window: NSWindow) -> WindowDialogCoordinator {
        let identifier = ObjectIdentifier(window)
        if let coordinator = coordinators[identifier] {
            if !coordinator.isOwnerClosed,
               coordinator.ownerWindowForPresentation === window {
                return coordinator
            }
            coordinator.ownerDidClose()
        }
        let coordinator = WindowDialogCoordinator(ownerWindow: window) {
            coordinators.removeValue(forKey: identifier)
            if let binding = projectBindings.removeValue(forKey: identifier),
               let owner = binding.window {
                binding.projectManager?.unbindDialogOwnerWindow(owner)
            }
        }
        coordinators[identifier] = coordinator
        return coordinator
    }

    /// Registers the weak project → window anchor and returns its shared
    /// per-window presentation context.
    @discardableResult
    static func register(
        window: NSWindow,
        projectManager: ProjectManager
    ) -> DialogPresentationContext {
        // A project owns one document window. SwiftUI can replace that
        // window during scene restoration, so retire every obsolete binding
        // (and abort its queued sheets) before installing the new anchor.
        let obsoleteWindows: [NSWindow] = projectBindings.values.compactMap { binding in
            guard binding.projectManager === projectManager,
                  let boundWindow = binding.window,
                  boundWindow !== window else {
                return nil
            }
            return boundWindow
        }
        for obsoleteWindow in obsoleteWindows {
            ownerDidClose(obsoleteWindow)
        }

        let identifier = ObjectIdentifier(window)
        if let previous = projectBindings[identifier],
           let previousWindow = previous.window,
           previous.projectManager !== projectManager {
            // The same NSWindow can be reused for a different project during
            // scene restoration. A coordinator is presentation authority for
            // the *binding generation*, not merely the NSWindow identity:
            // retire it before installing B so active/queued requests captured
            // by A can never appear over B.
            if let previousCoordinator = coordinators[identifier] {
                previousCoordinator.ownerDidClose()
            } else {
                projectBindings.removeValue(forKey: identifier)
                previous.projectManager?.unbindDialogOwnerWindow(previousWindow)
            }
        }
        let coordinator = coordinator(for: window)
        projectBindings[identifier] = ProjectBinding(
            window: window,
            projectManager: projectManager
        )
        projectManager.bindDialogOwnerWindow(window)
        return DialogPresentationContext(coordinator: coordinator)
    }

    /// Explicit lifecycle hook used by the window delegate and tests. The
    /// coordinator also observes `willClose`, so duplicate calls are harmless.
    static func ownerDidClose(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        if let coordinator = coordinators[identifier] {
            coordinator.ownerDidClose()
            return
        }
        if let binding = projectBindings.removeValue(forKey: identifier) {
            binding.projectManager?.unbindDialogOwnerWindow(window)
        }
    }

    static func context(for window: NSWindow?) -> DialogPresentationContext {
        DialogPresentationContext(window: window)
    }

    static func forKeyWindow() -> DialogPresentationContext {
        guard let keyWindow = NSApp.keyWindow else { return .unscoped }
        return context(for: keyWindow.sheetParent ?? keyWindow)
    }

    /// Captures a visible application window for app-global decisions such
    /// as Quit. A background project deliberately has no project owner, but
    /// its retained terminal still needs a place to ask whether Quit should
    /// stop it. Prefer the current key/main window, then any visible window;
    /// if none exists the returned context fails closed.
    static func forApplicationWindow() -> DialogPresentationContext {
        var candidates: [NSWindow] = []
        if let keyWindow = NSApp.keyWindow {
            candidates.append(keyWindow)
        }
        if let mainWindow = NSApp.mainWindow {
            candidates.append(mainWindow)
        }
        candidates.append(contentsOf: NSApp.windows)
        let owner = candidates
            .map { $0.sheetParent ?? $0 }
            .first(where: { isEligibleApplicationOwner($0) })
        return context(for: owner)
    }

    static func isEligibleApplicationOwner(_ window: NSWindow) -> Bool {
        window.isVisible && !window.isMiniaturized
    }

    /// Captures the current project window. Welcome and Settings windows are
    /// intentionally excluded from document/project decisions.
    static func forKeyProject() -> DialogPresentationContext {
        guard let keyWindow = NSApp.keyWindow else { return .unscoped }
        let window = keyWindow.sheetParent ?? keyWindow
        if projectManager(for: window) != nil {
            return context(for: window)
        }
        guard let delegate = window.delegate as? CloseDelegate else {
            return .unscoped
        }
        return register(window: window, projectManager: delegate.projectManager)
    }

    /// Resolves the weak window anchor owned by `projectManager`. This remains
    /// valid even if SwiftUI temporarily replaces the NSWindow delegate.
    static func forProject(_ projectManager: ProjectManager) -> DialogPresentationContext {
        context(for: projectManager.dialogOwnerWindow)
    }

    static func projectManager(for window: NSWindow?) -> ProjectManager? {
        guard let window else { return nil }
        let identifier = ObjectIdentifier(window)
        guard let binding = projectBindings[identifier] else { return nil }
        guard binding.window === window else {
            if let previousWindow = binding.window {
                binding.projectManager?.unbindDialogOwnerWindow(previousWindow)
            }
            projectBindings.removeValue(forKey: identifier)
            return nil
        }
        guard let projectManager = binding.projectManager else {
            projectBindings.removeValue(forKey: identifier)
            return nil
        }
        return projectManager
    }
}

// MARK: - Native sheet adapters

extension NSAlert {
    @discardableResult
    func runSheet(on context: DialogPresentationContext) async -> NSApplication.ModalResponse {
        guard let capturedOwner = context.nsWindow,
              capturedOwner.isVisible,
              !capturedOwner.isMiniaturized else {
            return .abort
        }
        return await context.present(
            start: { owner, completion in
                guard owner.isVisible, !owner.isMiniaturized else {
                    completion(.abort)
                    return
                }
                self.beginSheetModal(for: owner, completionHandler: completion)
            },
            cancel: { owner in
                guard self.window.sheetParent === owner else { return }
                owner.endSheet(self.window, returnCode: .abort)
            }
        )
    }
}

extension NSSavePanel {
    func runSheet(on context: DialogPresentationContext) async -> NSApplication.ModalResponse {
        guard let capturedOwner = context.nsWindow,
              capturedOwner.isVisible,
              !capturedOwner.isMiniaturized else {
            return .abort
        }
        return await context.present(
            start: { owner, completion in
                guard owner.isVisible, !owner.isMiniaturized else {
                    completion(.abort)
                    return
                }
                self.beginSheetModal(for: owner, completionHandler: completion)
            },
            cancel: { _ in
                self.cancel(nil)
            }
        )
    }
}
