#!/usr/bin/env python3
"""Run exact reset sources inside an owned fake application domain, never Pine's.

Pass --source-root /path/to/base to demonstrate failure on the pre-fix sources.
The probe retains its bundle/logs for diagnosis and does not launch NSApplication.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parent.parent)
args = parser.parse_args()
source = args.source_root
root = Path(tempfile.mkdtemp(prefix='pine-state-isolation-probe-'))
app = root / 'Fixture.app' / 'Contents'
(app / 'MacOS').mkdir(parents=True)
identity = 'PineTests.OwnedProduction.' + str(uuid.uuid4())
namespace = str(uuid.uuid4()).upper()
suite = 'PineUITests.State.' + namespace
(app / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': identity,
    'CFBundleExecutable': 'Fixture',
    'CFBundlePackageType': 'APPL',
}))
context = source / 'Pine/PineStorageContext.swift'
if context.exists():
    (root / 'Context.swift').write_text(context.read_text())
else:
    (root / 'Context.swift').write_text('import Foundation\n')
font = source / 'Pine/FontSizeSettings.swift'
(root / 'Font.swift').write_text(font.read_text())
session = (source / 'Pine/SessionState.swift').read_text()
reset = re.search(r'    static func removeAll\(.*?\n    }', session, re.S)
if reset is None:
    raise SystemExit('Cannot find exact SessionState.removeAll source')
(root / 'Session.swift').write_text('''import Foundation
@MainActor enum SessionState {
    private static let legacyKey = "lastSessionState"
    private static let perProjectPrefix = "sessionState:"
''' + reset.group() + '\n}\n')
(root / 'Probe.swift').write_text('''import AppKit
import Darwin
@main struct Probe {
    @MainActor static func main() {
        let environment = ProcessInfo.processInfo.environment
        let identity = environment["PROBE_OWNED_ID"]!
        // This check precedes EVERY defaults write, including the base probe.
        guard Bundle.main.bundleIdentifier == identity,
              identity.hasPrefix("PineTests.OwnedProduction."),
              let requestedSuiteName = environment["PROBE_SUITE"],
              requestedSuiteName.hasPrefix("PineUITests.State.") else {
            fatalError("Probe is not in its owned fake application domain")
        }
        let suiteName = PROBE_SELECTED_SUITE
        let suite = UserDefaults(suiteName: suiteName)!
        let production = UserDefaults.standard
        defer {
            production.removePersistentDomain(forName: identity)
            suite.removePersistentDomain(forName: suiteName)
        }
        let sessionKey = "sessionState:/owned-probe"
        production.set("preserved", forKey: sessionKey)
        production.set(17, forKey: "editorFontSize")
        suite.set("test", forKey: sessionKey)
        suite.set(16, forKey: "editorFontSize")
        SessionState.removeAll()
        FontSizeSettings().reset()
        guard production.string(forKey: sessionKey) == "preserved",
              production.double(forKey: "editorFontSize") == 17,
              suite.object(forKey: sessionKey) == nil,
              suite.double(forKey: "editorFontSize") == 13 else {
            print("owned session", production.string(forKey: sessionKey) as Any, "font", production.double(forKey: "editorFontSize"), "test session", suite.object(forKey: sessionKey) as Any, "font", suite.double(forKey: "editorFontSize"))
            print("FAIL: default resets crossed the owned production/test boundary")
            exit(1)
        }
        print("PASS: default session/font resets only changed the owned test suite")
    }
}
'''.replace('PROBE_SELECTED_SUITE', 'PineStorageContext.suiteName' if context.exists() else 'requestedSuiteName'))
if context.exists():
    probe = root / 'Probe.swift'
    probe.write_text(probe.read_text().replace(
        'print("PASS: default session/font resets only changed the owned test suite")',
        '''let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let ownedProduction = base.appendingPathComponent("OwnedProduction")
        try! FileManager.default.createDirectory(at: ownedProduction, withIntermediateDirectories: true)
        let sentinel = ownedProduction.appendingPathComponent("recovery")
        try! Data("preserved".utf8).write(to: sentinel)
        try! FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("PineTestState"), withDestinationURL: ownedProduction
        )
        do {
            _ = try PineStorageContext.prepareTestApplicationSupportDirectory(base: base, namespace: UUID())
            fatalError("Accepted stale test storage symlink")
        } catch { }
        precondition(try! Data(contentsOf: sentinel) == Data("preserved".utf8))
        var acceptedRedirect = false
        for component in ["Pine", "Pine/Recovery", "Pine/Recovery/project", "Pine/Recovery/project/snapshot.json"] {
            let ownedBase = base.appendingPathComponent(UUID().uuidString)
            try! FileManager.default.createDirectory(at: ownedBase, withIntermediateDirectories: true)
            let namespace = UUID()
            let scope = try! PineStorageContext.prepareTestApplicationSupportDirectory(base: ownedBase, namespace: namespace)
            let link = scope.appendingPathComponent(component)
            try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: component.hasSuffix(".json") ? sentinel : ownedProduction
            )
            do {
                _ = try PineStorageContext.prepareTestApplicationSupportDirectory(base: ownedBase, namespace: namespace)
                print("FAIL: accepted stale descendant symlink", component)
                acceptedRedirect = true
            } catch { }
            precondition(try! Data(contentsOf: sentinel) == Data("preserved".utf8))
        }
        let hardlinkBase = base.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: hardlinkBase, withIntermediateDirectories: true)
        let hardlinkNamespace = UUID()
        let hardlinkScope = try! PineStorageContext.prepareTestApplicationSupportDirectory(
            base: hardlinkBase, namespace: hardlinkNamespace
        )
        let internalLock = hardlinkScope.appendingPathComponent("lock")
        try! Data("internal".utf8).write(to: internalLock)
        try! FileManager.default.linkItem(at: internalLock, to: hardlinkScope.appendingPathComponent("guard"))
        precondition(try! PineStorageContext.prepareTestApplicationSupportDirectory(
            base: hardlinkBase, namespace: hardlinkNamespace
        ) == hardlinkScope)
        try! FileManager.default.linkItem(at: sentinel, to: hardlinkScope.appendingPathComponent("snapshot.json"))
        do {
            _ = try PineStorageContext.prepareTestApplicationSupportDirectory(base: hardlinkBase, namespace: hardlinkNamespace)
            print("FAIL: accepted stale hardlink outside namespace")
            acceptedRedirect = true
        } catch { }
        precondition(try! Data(contentsOf: sentinel) == Data("preserved".utf8))
        if acceptedRedirect { exit(1) }
        try! FileManager.default.removeItem(at: hardlinkScope.appendingPathComponent("snapshot.json"))
        let nested = hardlinkScope.appendingPathComponent("nested")
        try! FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try! Data("fixture".utf8).write(to: nested.appendingPathComponent("entry"))
        do {
            _ = try PineStorageContext.prepareTestApplicationSupportDirectory(
                base: hardlinkBase, namespace: hardlinkNamespace, maximumDepth: 1
            )
            fatalError("Accepted over-depth fixture")
        } catch { }
        do {
            _ = try PineStorageContext.prepareTestApplicationSupportDirectory(
                base: hardlinkBase, namespace: hardlinkNamespace, maximumEntries: 1
            )
            fatalError("Accepted over-budget fixture")
        } catch { }
        precondition(mkfifo(hardlinkScope.appendingPathComponent("fifo").path, 0o600) == 0)
        do {
            _ = try PineStorageContext.prepareTestApplicationSupportDirectory(base: hardlinkBase, namespace: hardlinkNamespace)
            fatalError("Accepted special-file fixture")
        } catch { }
        print("PASS: resets isolated; redirects/special files rejected; internal links/bounds preserved")'''
    ))
command = [
    'xcrun', 'swiftc', '-swift-version', '6', '-D', 'PINE_TEST_HOST',
    '-module-cache-path', str(root / 'ModuleCache'),
    str(root / 'Context.swift'), str(root / 'Font.swift'),
    str(root / 'Session.swift'), str(root / 'Probe.swift'),
    '-o', str(app / 'MacOS/Fixture'),
]
environment = os.environ.copy()
environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
print('Probe artifacts:', root, flush=True)
subprocess.run(command, env=environment, check=True)
environment.update({
    'PROBE_OWNED_ID': identity,
    'PROBE_SUITE': suite,
    'PINE_TEST_STATE_NAMESPACE': namespace,
})
modes = ['valid', 'missing', 'malformed'] if context.exists() else ['valid']
for mode in modes:
    if mode == 'missing':
        environment.pop('PINE_TEST_STATE_NAMESPACE', None)
    elif mode == 'malformed':
        environment['PINE_TEST_STATE_NAMESPACE'] = '../invalid-production-domain'
    print('Namespace mode:', mode, flush=True)
    result = subprocess.run([str(app / 'MacOS/Fixture')], env=environment, check=False)
    if result.returncode:
        raise SystemExit(result.returncode)


entry = source / 'Pine/PineEntryPoint.swift'
if entry.exists():
    # Exercise the actual earliest entry point as an ordinary build. The stub
    # returns 42 and updates an owned fake production sentinel if initialization
    # is reached. Rejected vectors must leave it intact. No NSApplication or
    # actual production domain is ever initialized.
    (root / 'AppStub.swift').write_text('''import Foundation
struct PineApp {
    static func main() {
        precondition(PineStorageContext.launchIsSafe(
            testHost: false, bundleIdentifier: "io.github.batonogov.pine",
            arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment
        ))
        if let expectedIdentity = ProcessInfo.processInfo.environment["PROBE_EXPECTED_BUNDLE_ID"] {
            precondition(Bundle.main.bundleIdentifier == expectedIdentity)
        }
        let path = ProcessInfo.processInfo.environment["PROBE_GUARD_SENTINEL"]!
        let sentinel = URL(fileURLWithPath: path)
        precondition(sentinel.lastPathComponent == "guard-owned-production")
        precondition(sentinel.deletingLastPathComponent().lastPathComponent.hasPrefix("pine-state-isolation-probe-"))
        try! Data("entered stub application".utf8).write(to: sentinel)
        exit(42)
    }
}
''')
    guard_binary = app / 'MacOS/Guard'
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-module-cache-path', str(root / 'ModuleCache'),
        str(context), str(entry), str(root / 'AppStub.swift'), '-o', str(guard_binary),
    ], env=environment, check=True)
    ordinary_environment = environment.copy()
    for key in ['PINE_TEST_STATE_NAMESPACE',
                'PINE_APPLICATION_LIFECYCLE_CONFIG', 'XCTestConfigurationFilePath',
                'XCTestBundlePath', 'XCInjectBundleInto']:
        ordinary_environment.pop(key, None)
    fault_keys = ['PINE_PERSISTENCE_FAULT', 'PINE_PERSISTENCE_PAUSE', 'PINE_PERSISTENCE_CHECKPOINT_DIRECTORY']
    for key in list(ordinary_environment):
        if key.startswith('PINE_UI_TEST_') or key in fault_keys:
            ordinary_environment.pop(key)
    sentinel = root / 'guard-owned-production'
    ordinary_environment['PROBE_GUARD_SENTINEL'] = str(sentinel)
    unsafe_flags = [
        '--reset-state', '--application-lifecycle-process-test', '--ui-test-agent-recovery',
        '--ui-test-agent-vendor-recovery', '--ui-test-live-agent', '--ui-test-a11y-dirty-buffer',
        '--ui-test-agent-attention', '--ui-test-agent-activity-all', '--ui-test-agent-activity-heuristic',
        '--ui-test-agent-inbox-marketing', '--ui-test-dark-appearance', '--ui-test-future-fixture', '--ui-test-',
    ]
    unsafe_environment_keys = [
        'PINE_TEST_STATE_NAMESPACE', 'PINE_UI_TEST_SETTINGS_SUITE', 'PINE_UI_TEST_DIRTY_FILE',
        'PINE_UI_TEST_DIRTY_MARKER', 'PINE_UI_TEST_FUTURE_FIXTURE', 'PINE_UI_TEST_',
        'PINE_APPLICATION_LIFECYCLE_CONFIG', 'XCTestConfigurationFilePath', 'XCTestBundlePath',
        'XCInjectBundleInto', *fault_keys,
    ]
    unsafe_vectors = [(flag, [flag], {}) for flag in unsafe_flags]
    unsafe_vectors += [(key + '=' + value, [], {key: value})
                       for key in unsafe_environment_keys for value in ['', 'malformed']]
    configured_values = {
        'PINE_UI_TEST_SETTINGS_SUITE': 'PineUITests.Settings.owned-fixture',
        'PINE_UI_TEST_DIRTY_FILE': 'main.swift', 'PINE_UI_TEST_DIRTY_MARKER': '// owned dirty fixture',
        'PINE_PERSISTENCE_FAULT': 'session:before-atomic-replace:permission-denied',
        'PINE_PERSISTENCE_PAUSE': 'session:before-atomic-replace',
        'PINE_PERSISTENCE_CHECKPOINT_DIRECTORY': '/owned/fixture-checkpoint',
    }
    unsafe_vectors += [(key + '=' + value, [], {key: value}) for key, value in configured_values.items()]
    unsafe_vectors += [('configured pause with checkpoint directory', [], {
        'PINE_PERSISTENCE_PAUSE': configured_values['PINE_PERSISTENCE_PAUSE'],
        'PINE_PERSISTENCE_CHECKPOINT_DIRECTORY': configured_values['PINE_PERSISTENCE_CHECKPOINT_DIRECTORY'],
    }), ('configured dirty buffer', ['--ui-test-a11y-dirty-buffer'], {
        'PINE_UI_TEST_DIRTY_FILE': configured_values['PINE_UI_TEST_DIRTY_FILE'],
        'PINE_UI_TEST_DIRTY_MARKER': configured_values['PINE_UI_TEST_DIRTY_MARKER'],
    })]
    rejected = True
    for label, arguments, overrides in unsafe_vectors:
        sentinel.write_text('preserved')
        vector_environment = {**ordinary_environment, 'PINE_OPEN_PROJECT': '/owned/fixture-project', **overrides}
        result = subprocess.run([str(guard_binary), *arguments], env=vector_environment, check=False)
        if result.returncode != 78 or sentinel.read_text() != 'preserved':
            print('FAIL: ordinary entry accepted unsafe vector:', label, flush=True)
            rejected = False
    sentinel.write_text('preserved')
    result = subprocess.run([str(guard_binary)], env=ordinary_environment, check=False)
    if result.returncode != 42 or sentinel.read_text() != 'entered stub application':
        raise SystemExit('FAIL: ordinary application launch was changed')
    # Exact app arguments and environment explicitly supplied by the unchanged
    # release-artifact smoke helper (no release tooling or real app is run).
    release_arguments = [
        '--disable-agent-detection', '--disable-metal', '--disable-quick-terminal',
        '--disable-terminal-seeding', '-ApplePersistenceIgnoreState', 'YES',
        '-AppleLanguages', '(en)', '-AppleLocale', 'en_US',
    ]
    release_environment = {
        **ordinary_environment, 'HOME': '/owned/fixture-home', 'CFFIXED_USER_HOME': '/owned/fixture-home',
        'TMPDIR': '/owned/fixture-home/tmp', 'PINE_DISABLE_AGENT_DETECTION': '1',
        'PINE_DISABLE_METAL': '1', 'PINE_DISABLE_QUICK_TERMINAL': '1',
        'PINE_OPEN_PROJECT': '/owned/fixture-project',
    }
    for overrides in [{}, {'PINE_SEARCH_QUERY': 'normal query'}]:
        result = subprocess.run([str(guard_binary), *release_arguments],
                                env={**release_environment, **overrides}, check=False)
        if result.returncode != 42:
            raise SystemExit('FAIL: release-smoke or normal search launch contract was changed')
    print('PASS: ordinary/release-smoke/search vectors reach harmless stub initialization', flush=True)
    # Metadata belongs only to this harmless stub bundle. A build without the
    # test compile flag must refuse the reserved test identity even with no
    # fixture marker; the stub never accesses preferences or NSApplication.
    metadata_path = app / 'Info.plist'
    ordinary_metadata = metadata_path.read_bytes()
    reserved_identity = 'io.github.batonogov.pine.test-host'
    mismatched_metadata = plistlib.loads(ordinary_metadata)
    mismatched_metadata['CFBundleIdentifier'] = reserved_identity
    try:
        metadata_path.write_bytes(plistlib.dumps(mismatched_metadata))
        sentinel.write_text('preserved')
        result = subprocess.run([str(guard_binary)], env={
            **ordinary_environment, 'PROBE_EXPECTED_BUNDLE_ID': reserved_identity,
        }, check=False)
        if result.returncode != 78 or sentinel.read_text() != 'preserved':
            print('FAIL: ordinary build accepted reserved test identity before initialization', flush=True)
            rejected = False
        else:
            print('PASS: reserved test identity without test compile mode exits before initialization', flush=True)
    finally:
        metadata_path.write_bytes(ordinary_metadata)
    if not rejected:
        raise SystemExit(1)
    print('PASS: every private fixture vector exits before initialization and preserves its owned sentinel')

if entry.exists():
    # Exercise the real entry's scheduler with harmless storage and app stubs.
    # The fake app pumps a bounded CF loop and requires a main-queue callback;
    # no NSApplication, preferences, user files, or actual app identity is used.
    (root / 'SchedulingStorage.swift').write_text('''import Foundation
nonisolated enum PineStorageContext {
    static let isTestHost = true
    static var applicationSupportDirectory: URL {
        guard !Thread.isMainThread else { print("FAIL: storage preparation ran on main thread"); exit(1) }
        let callback = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { callback.signal() }
        guard callback.wait(timeout: .now() + 1) == .success else {
            print("FAIL: bootstrap did not process main-queue events during preparation")
            exit(1)
        }
        return URL(fileURLWithPath: "/unused-owned-probe")
    }
    static func launchIsSafe(testHost: Bool, bundleIdentifier: String?, arguments: [String], environment: [String: String]) -> Bool { true }
}
''')
    (root / 'SchedulingApp.swift').write_text('''import Foundation
import CoreFoundation
@MainActor enum PineApp {
    static var scheduled = false
    static func main() {
        DispatchQueue.main.async { scheduled = true }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.defaultMode)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while !scheduled && DispatchTime.now().uptimeNanoseconds < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false)
        }
        CFRunLoopTimerInvalidate(timer)
        guard scheduled else {
            print("FAIL: application main loop cannot drain main-queue callbacks")
            exit(1)
        }
        print("PASS: synchronous application main loop drains main-queue callbacks")
        exit(0)
    }
}
''')
    scheduling_binary = root / 'SchedulingProbe'
    subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-module-cache-path', str(root / 'ModuleCache'), str(entry),
        str(root / 'SchedulingStorage.swift'), str(root / 'SchedulingApp.swift'),
        '-o', str(scheduling_binary),
    ], env=ordinary_environment, check=True)
    result = subprocess.run([str(scheduling_binary)], env=ordinary_environment, check=False, timeout=35)
    if result.returncode:
        raise SystemExit(result.returncode)
