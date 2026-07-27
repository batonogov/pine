//
//  GlobalHotkeyManager.swift
//  Pine
//
//  Registers a system-wide hotkey via Carbon's `RegisterEventHotKey` so that
//  Pine's quick terminal can be toggled from any application (#1113).
//
//  Carbon global hotkeys — unlike `CGEvent.tap` or `NSEvent.addGlobalMonitor`
//  — do NOT require Accessibility permission and work inside the App
//  Sandbox (used by Maccy, Raycast, etc.). They fire only while the
//  registering app is running.
//

import Carbon.HIToolbox
import Foundation

/// Carbon modifiers (the `RegisterEventHotKey` API uses the legacy modifier
/// bit-field, not `NSEvent.ModifierFlags`). See <Events.h>.
private let carbonControl: UInt32 = UInt32(controlKey)
private let carbonOption: UInt32 = UInt32(optionKey)
private let carbonCommand: UInt32 = UInt32(cmdKey)
private let carbonShift: UInt32 = UInt32(shiftKey)

/// Owner of one system-wide hotkey. `nonisolated` because the Carbon event
/// handler runs off the main thread (the handler main-hops internally); the
/// stored `onTrigger` is set before `register(...)` is called and never
/// re-assigned while the hotkey is active (see ``unregister()``).
///
/// Usage:
/// ```swift
/// let manager = GlobalHotkeyManager()
/// manager.onTrigger = { [weak quickTerminal] in quickTerminal?.toggle() }
/// manager.register(keyCode: UInt32(kVK_Space),
///                   carbonModifiers: carbonControl | carbonOption)
/// ```
nonisolated final class GlobalHotkeyManager {
    /// Fires on the main thread when the registered hotkey is pressed.
    /// Set this before calling ``register(keyCode:carbonModifiers:)``.
    ///
    /// `@Sendable` so the Carbon handler can dispatch it to the main thread
    /// without sending the (non-Sendable) manager itself. `nonisolated(unsafe)`
    /// documents the contract: written from the main thread in `register`,
    /// read only after the Carbon handler fires — which is strictly after
    /// `RegisterEventHotKey` returns (happens-before).
    nonisolated(unsafe) var onTrigger: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// Tracks whether `InstallEventHandler` succeeded so `unregister()` knows
    /// whether to remove it. Mutated only alongside `register`/`unregister`,
    /// which are called from the main thread.
    private var handlerInstalled = false

    deinit { unregister() }

    /// Registers the hotkey. Returns `true` on success.
    /// `keyCode` is a Carbon virtual key code (e.g. `kVK_Space` = 49);
    /// `carbonModifiers` is a bitwise-OR of `controlKey` / `optionKey` /
    /// `cmdKey` / `shiftKey`. Calling twice without ``unregister()`` is a
    /// no-op (the second call unregisters first).
    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        unregister()

        // 1. Install a Carbon keyboard event handler on the application
        //    target, if one is not already installed. The handler receives
        //    `self` as unretained userdata — valid for the manager's lifetime
        //    (the manager is owned by AppDelegate and freed only on quit, at
        //    which point the hotkey is unregistered first).
        if !handlerInstalled {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let installErr = InstallEventHandler(
                GetApplicationEventTarget(),
                hotKeyHandler,
                1,
                &spec,
                selfPtr,
                &eventHandler
            )
            guard installErr == noErr else { return false }
            handlerInstalled = true
        }

        // 2. Register the actual hotkey. The signature is the FourCharCode
        //    'PINE' (0x50494E45) — opaque identifier Carbon uses to find the
        //    hotkey for `UnregisterEventHotKey`.
        let hotKeyID = EventHotKeyID(signature: OSType(0x50494E45), id: 1)
        let regErr = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &hotKeyRef
        )
        return regErr == noErr
    }

    /// Unregisters the hotkey and removes the Carbon event handler. Safe to
    /// call multiple times.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if handlerInstalled, let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
            handlerInstalled = false
        }
    }

    var isRegistered: Bool { hotKeyRef != nil }

    // MARK: - Carbon callback

    /// The C-callback Carbon invokes when the hotkey fires. Captures nothing;
    /// recovers `self` from the userdata pointer installed in
    /// ``register(keyCode:carbonModifiers:)`` and main-hops so `onTrigger`
    /// runs on the main thread (SwiftUI / AppKit require it). Must be
    /// `@convention(c)` — a Swift closure would capture context and break.
    private let hotKeyHandler: @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus = { _, _, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        // Read the trigger before the hop so only the (Sendable) closure is
        // sent across the actor boundary, not the manager itself.
        let trigger = manager.onTrigger
        DispatchQueue.main.async {
            trigger?()
        }
        return noErr
    }
}

// MARK: - Modifier convenience

extension GlobalHotkeyManager {
    /// Convenience for the default Pine quick-terminal hotkey: ⌃⌥Space.
    /// `controlKey | optionKey` in Carbon bit-field, `kVK_Space` (49) keyCode.
    static var defaultQuickTerminalModifiers: UInt32 { carbonControl | carbonOption }
    static var defaultQuickTerminalKeyCode: UInt32 { UInt32(kVK_Space) }

    /// Re-registers the hotkey from `QuickTerminalSettings` (or unregisters
    /// it when disabled). Idempotent — safe to call on every settings change.
    ///
    /// Does **not** touch `onTrigger` — the caller owns the trigger routing
    /// (typically `quickTerminalCoordinator.toggle()`). This method only
    /// reflects the enabled flag + key code + modifiers.
    @MainActor
    func applyQuickTerminalSettings(_ settings: QuickTerminalSettings) {
        guard settings.enabled else {
            unregister()
            return
        }
        register(keyCode: settings.keyCode, carbonModifiers: settings.modifiers)
    }
}
