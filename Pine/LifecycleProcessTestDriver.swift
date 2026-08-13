//
//  LifecycleProcessTestDriver.swift
//  Pine
//
//  Debug-only process fixture for the full application lifecycle release gate.
//

#if DEBUG
import Foundation

/// Installs deterministic dirty-editor and live-PTY state in the real Pine
/// process. The process test can request a second terminal generation with
/// a one-shot control file while AppKit's Quit sheet is visible, without
/// reaching through a
/// model-only test seam.
@MainActor
final class LifecycleProcessTestDriver {
    static let shared = LifecycleProcessTestDriver()

    private weak var projectManager: ProjectManager?
    private var terminalPaneID: PaneID?
    private var generationControl: DispatchSourceTimer?
    private var diagnosticsDirectory: URL?
    private var generation = 0

    private init() {}

    func startIfRequested(projectManager: ProjectManager) {
        guard CommandLine.arguments.contains(
            "--ui-test-lifecycle-process"
        ) else { return }
        guard generationControl == nil else { return }
        guard let diagnosticsDirectory = Self.diagnosticsDirectory() else {
            assertionFailure(
                "Lifecycle process fixture requires a diagnostics directory"
            )
            return
        }
        self.projectManager = projectManager
        self.diagnosticsDirectory = diagnosticsDirectory

        if ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_FIXTURE_DIRTY"
        ] != "0" {
            let dirtyFile = projectManager.rootURL?
                .appendingPathComponent("dirty.swift")
            if let dirtyFile,
               case .opened = projectManager.activeTabManager.openTab(
                   url: dirtyFile
               ) {
                projectManager.activeTabManager.updateContent(
                    "let lifecycleFixtureIsDirty = true\n"
                )
                record("dirty-buffer-ready")
            } else {
                record("dirty-buffer-failed")
            }
        }

        spawnTerminalGeneration()
        installGenerationControl()
        record("fixture-ready")
    }

    private func installGenerationControl() {
        guard let diagnosticsDirectory else { return }
        let request = diagnosticsDirectory.appendingPathComponent(
            "request-next-generation"
        )
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        source.schedule(
            deadline: .now(),
            repeating: .milliseconds(50)
        )
        source.setEventHandler { [weak self] in
            guard FileManager.default.fileExists(atPath: request.path),
                  (try? FileManager.default.removeItem(at: request)) != nil
            else { return }
            Task { @MainActor [weak self] in
                self?.spawnTerminalGeneration()
            }
        }
        source.resume()
        generationControl = source
    }

    private func spawnTerminalGeneration() {
        guard let projectManager,
              let rootURL = projectManager.rootURL,
              let diagnosticsDirectory else { return }
        generation += 1
        let process = TerminalInitialProcess(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "echo $$ > \"$1/owned-$2.pid\"; "
                    + "child=0; "
                    + "trap 'test \"$child\" -le 0 || kill \"$child\" "
                    + "2>/dev/null; exit 0' HUP INT TERM; "
                    + "while :; do /bin/sleep 60 & child=$!; "
                    + "echo $child > \"$1/owned-$2-child.pid\"; "
                    + "wait \"$child\"; done",
                "pine-lifecycle-fixture",
                diagnosticsDirectory.path,
                String(generation),
            ]
        )
        if let terminalPaneID {
            _ = projectManager.paneManager.addTerminalTab(
                in: terminalPaneID,
                workingDirectory: rootURL,
                initialProcess: process
            )
        } else {
            terminalPaneID = projectManager.paneManager
                .createTerminalPaneAtBottom(
                    workingDirectory: rootURL,
                    initialProcess: process
                )
        }
        record("terminal-generation-\(generation)-requested")
    }

    private func record(_ phase: String) {
        guard let diagnosticsDirectory else { return }
        LifecycleProcessDiagnostics.record(
            phase,
            in: diagnosticsDirectory
        )
    }

    private static func diagnosticsDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[
            "PINE_LIFECYCLE_DIAGNOSTICS_DIRECTORY"
        ], path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        } catch {
            return nil
        }
    }
}

nonisolated enum LifecycleProcessDiagnostics {
    private static let queue = DispatchQueue(
        label: "com.pine.lifecycle-process-diagnostics",
        qos: .utility
    )

    static func record(_ phase: String, in directory: URL) {
        queue.async {
            let url = directory.appendingPathComponent("phases.log")
            let line = Data("\(phase)\n".utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil
                )
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return
            }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.synchronize()
            } catch {
                return
            }
        }
    }
}
#endif
