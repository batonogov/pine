//
//  FocusDiagnosticsProbe.swift
//  Pine
//
//  Throwaway diagnostics for #1544. Not shipped behaviour: it does nothing
//  unless PINE_FOCUS_LOG names a file, which only the probe UI test sets.
//
//  The question it answers cannot be asked from XCUITest — `hasFocus` is
//  never populated on macOS, and the UI shards publish no result bundle, so
//  who holds first responder when a navigation key arrives has never been
//  observed. The app has to say it out loud.
//
//  Delete with the probe once #1544 is understood.
//

import AppKit

@MainActor
enum FocusDiagnosticsProbe {
    private static var monitor: Any?
    private static var logURL: URL?

    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["PINE_FOCUS_LOG"],
              !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        logURL = url
        FileManager.default.createFile(atPath: path, contents: nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Report only, never consume: the event must reach whatever would
            // normally handle it, or the probe would change what it measures.
            append(describe(event))
            return event
        }
    }

    private static func describe(_ event: NSEvent) -> String {
        let window = event.window ?? NSApp.keyWindow
        let responder = window?.firstResponder
        let chain = responderChain(from: responder)
        return """
        keyCode=\(event.keyCode) \
        window=\(window.map { String(describing: type(of: $0)) } ?? "nil") \
        firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "nil") \
        chain=[\(chain)]
        """
    }

    private static func responderChain(from responder: NSResponder?) -> String {
        var names: [String] = []
        var current = responder
        var depth = 0
        while let node = current, depth < 6 {
            names.append(String(describing: type(of: node)))
            current = node.nextResponder
            depth += 1
        }
        return names.joined(separator: " → ")
    }

    private static func append(_ line: String) {
        guard let logURL,
              let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
