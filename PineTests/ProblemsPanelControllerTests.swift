//
//  ProblemsPanelControllerTests.swift
//  PineTests
//
//  Exact project/pane/document/revision ownership for Problems (#1236).
//

import Foundation
import Testing

@testable import Pine

@Suite("Problems Panel Controller Ownership")
@MainActor
struct ProblemsPanelControllerTests {

    @Test("Config diagnostics require a live exact owner and preserve column")
    func exactOwnerAndColumn() throws {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }

        let owner = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.yml"
        )
        let diagnostic = makeDiagnostic(
            line: 4,
            column: 9,
            message: "missing value"
        )

        controller.setConfigDiagnostics(
            [diagnostic],
            owner: owner,
            contentRevision: 3
        )
        #expect(controller.flatDiagnostics.isEmpty)

        states = [state(owner, revision: 3, focused: true)]
        controller.setConfigDiagnostics(
            [diagnostic],
            owner: owner,
            contentRevision: 3
        )

        let entry = try #require(controller.flatDiagnostics.only)
        let target = try #require(controller.navigationTarget(for: entry))
        #expect(target.owner == owner)
        #expect(target.line == 4)
        #expect(target.column == 9)
        #expect(target.revision == .editor(3))
    }

    @Test("Owner from another project is rejected")
    func wrongProjectRejected() {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        let otherProject = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }

        let foreignOwner = otherProject.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.yml"
        )
        states = [state(foreignOwner, revision: 1)]
        controller.setConfigDiagnostics(
            [makeDiagnostic()],
            owner: foreignOwner,
            contentRevision: 1
        )

        #expect(controller.flatDiagnostics.isEmpty)
    }

    @Test("Same tab and URI in the wrong pane do not validate an owner")
    func wrongPaneRejected() {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }

        let tabID = UUID()
        let uri = "file:///project/a.yml"
        let submittedOwner = controller.documentOwner(
            paneID: PaneID(),
            tabID: tabID,
            uri: uri
        )
        let liveOwner = controller.documentOwner(
            paneID: PaneID(),
            tabID: tabID,
            uri: uri
        )
        states = [state(liveOwner, revision: 1)]

        controller.setConfigDiagnostics(
            [makeDiagnostic()],
            owner: submittedOwner,
            contentRevision: 1
        )

        #expect(controller.flatDiagnostics.isEmpty)
    }

    @Test("Tab switch and removal invalidate captured rows")
    func tabSwitchAndRemovalFailClosed() throws {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }

        let paneID = PaneID()
        let firstOwner = controller.documentOwner(
            paneID: paneID,
            tabID: UUID(),
            uri: "file:///project/first.yml"
        )
        states = [state(firstOwner, revision: 2)]
        controller.setConfigDiagnostics(
            [makeDiagnostic(message: "first")],
            owner: firstOwner,
            contentRevision: 2
        )
        let captured = try #require(controller.flatDiagnostics.only)

        let secondOwner = controller.documentOwner(
            paneID: paneID,
            tabID: UUID(),
            uri: "file:///project/second.yml"
        )
        states = [state(secondOwner, revision: 0)]
        #expect(controller.flatDiagnostics.isEmpty)
        #expect(controller.navigationTarget(for: captured) == nil)

        states = []
        controller.refreshDocumentOwnership()
        #expect(controller.flatDiagnostics.isEmpty)
        #expect(controller.navigationTarget(for: captured) == nil)
    }

    @Test("Content revision change hides old result and rejects stale replacement")
    func staleRevisionFailsClosed() throws {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }
        let owner = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.yml"
        )
        states = [state(owner, revision: 5)]
        controller.setConfigDiagnostics(
            [makeDiagnostic(message: "revision 5")],
            owner: owner,
            contentRevision: 5
        )
        let staleEntry = try #require(controller.flatDiagnostics.only)

        states = [state(owner, revision: 6)]
        #expect(controller.flatDiagnostics.isEmpty)
        #expect(controller.navigationTarget(for: staleEntry) == nil)

        controller.setConfigDiagnostics(
            [makeDiagnostic(message: "late revision 5")],
            owner: owner,
            contentRevision: 5
        )
        #expect(controller.flatDiagnostics.isEmpty)

        controller.setConfigDiagnostics(
            [makeDiagnostic(message: "revision 6")],
            owner: owner,
            contentRevision: 6
        )
        let current = try #require(controller.flatDiagnostics.only)
        #expect(current.diagnostic.message == "revision 6")
        #expect(current.revision == .editor(6))
    }

    @Test("Removing one duplicate-URI owner keeps the other pane's diagnostics")
    func removalIsOwnerScoped() {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }
        let uri = "file:///project/shared.yml"
        let first = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: uri
        )
        let second = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: uri
        )
        states = [
            state(first, revision: 1),
            state(second, revision: 8, focused: true)
        ]
        controller.setConfigDiagnostics(
            [makeDiagnostic(line: 1, message: "first pane")],
            owner: first,
            contentRevision: 1
        )
        controller.setConfigDiagnostics(
            [makeDiagnostic(line: 2, message: "second pane")],
            owner: second,
            contentRevision: 8
        )
        #expect(controller.flatDiagnostics.count == 2)

        controller.removeConfigDiagnostics(owner: first)

        #expect(controller.flatDiagnostics.count == 1)
        #expect(controller.flatDiagnostics.first?.owner == second)
        #expect(
            controller.flatDiagnostics.first?.diagnostic.message
                == "second pane"
        )
    }

    @Test("Ordering and semantic dedup are deterministic")
    func deterministicOrderingAndDedup() {
        var states: [ProblemsDocumentState] = []
        var lsp: [LSPProblemsDiagnostics] = []
        let controller = ProblemsPanelController(
            lspDiagnosticsProvider: { lsp }
        )
        controller.configureDocumentStatesProvider { states }
        let ownerA = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.yml"
        )
        let ownerB = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/b.yml"
        )
        states = [
            state(ownerB, revision: 2),
            state(ownerA, revision: 1, focused: true)
        ]

        let duplicate = makeDiagnostic(
            line: 2,
            column: 4,
            message: "duplicate",
            severity: .warning,
            source: "shared"
        )
        controller.setConfigDiagnostics(
            [
                makeDiagnostic(
                    line: 2,
                    column: nil,
                    message: "no column",
                    severity: .info,
                    source: "z"
                ),
                duplicate,
                makeDiagnostic(
                    line: 1,
                    column: 7,
                    message: "first",
                    severity: .error,
                    source: "a"
                )
            ],
            owner: ownerA,
            contentRevision: 1
        )
        controller.setConfigDiagnostics(
            [makeDiagnostic(line: 1, message: "file b")],
            owner: ownerB,
            contentRevision: 2
        )
        lsp = [
            LSPProblemsDiagnostics(
                uri: ownerA.uri,
                documentVersion: 11,
                contentRevision: 1,
                diagnostics: [duplicate]
            )
        ]

        let firstRead = controller.flatDiagnostics
        let secondRead = controller.flatDiagnostics
        #expect(firstRead.map(\.id) == secondRead.map(\.id))
        #expect(firstRead.count == 4)
        #expect(firstRead.map(\.diagnostic.message) == [
            "first",
            "no column",
            "duplicate",
            "file b"
        ])
        #expect(
            firstRead.first(where: {
                $0.diagnostic.message == "duplicate"
            })?.origin == .config
        )
        #expect(controller.groupedDiagnostics.map(\.uri) == [
            ownerA.uri,
            ownerB.uri
        ])
    }

    @Test("LSP diagnostics require one owner and an unchanged server revision")
    func lspOwnershipAndRevision() throws {
        var states: [ProblemsDocumentState] = []
        var lsp: [LSPProblemsDiagnostics] = []
        let controller = ProblemsPanelController(
            lspDiagnosticsProvider: { lsp }
        )
        controller.configureDocumentStatesProvider { states }
        let uri = "file:///project/a.swift"
        let first = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: uri
        )
        states = [state(first, revision: 4)]
        lsp = [
            LSPProblemsDiagnostics(
                uri: uri,
                documentVersion: 12,
                contentRevision: 4,
                diagnostics: [
                    makeDiagnostic(
                        line: 9,
                        column: 3,
                        message: "type mismatch",
                        source: "sourcekit-lsp"
                    )
                ]
            )
        ]

        let captured = try #require(controller.flatDiagnostics.only)
        #expect(
            captured.revision
                == .lsp(documentVersion: 12, contentRevision: 4)
        )

        let duplicateOwner = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: uri
        )
        states.append(state(duplicateOwner, revision: 0))
        #expect(controller.flatDiagnostics.isEmpty)
        #expect(controller.navigationTarget(for: captured) == nil)

        states = [state(first, revision: 4)]
        lsp[0] = LSPProblemsDiagnostics(
            uri: uri,
            documentVersion: 13,
            contentRevision: 4,
            diagnostics: lsp[0].diagnostics
        )
        #expect(controller.navigationTarget(for: captured) == nil)
        #expect(controller.flatDiagnostics.only?.revision
            == .lsp(documentVersion: 13, contentRevision: 4))
    }

    @Test("An LSP snapshot cannot be rebound to a newer editor revision")
    func lspSnapshotDoesNotRebindToNewContent() throws {
        var states: [ProblemsDocumentState] = []
        var lsp: [LSPProblemsDiagnostics] = []
        let controller = ProblemsPanelController(
            lspDiagnosticsProvider: { lsp }
        )
        controller.configureDocumentStatesProvider { states }
        let owner = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.swift"
        )
        states = [state(owner, revision: 4)]
        lsp = [
            LSPProblemsDiagnostics(
                uri: owner.uri,
                documentVersion: 12,
                contentRevision: 4,
                diagnostics: [makeDiagnostic(source: "sourcekit-lsp")]
            )
        ]

        let captured = try #require(controller.flatDiagnostics.only)
        states = [state(owner, revision: 5)]

        #expect(controller.flatDiagnostics.isEmpty)
        #expect(controller.navigationTarget(for: captured) == nil)
    }

    @Test("Stable semantic selection survives insertion and wraps")
    func stableSelectionAndWrap() throws {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }
        let owner = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.yml"
        )
        states = [state(owner, revision: 1)]
        let later = makeDiagnostic(line: 8, message: "later")
        controller.setConfigDiagnostics(
            [later],
            owner: owner,
            contentRevision: 1
        )
        let selected = try #require(controller.flatDiagnostics.only)
        controller.select(selected)

        let earlier = makeDiagnostic(line: 1, message: "earlier")
        controller.setConfigDiagnostics(
            [later, earlier],
            owner: owner,
            contentRevision: 1
        )
        #expect(controller.selectedDiagnostic?.id == selected.id)
        #expect(controller.nextDiagnostic()?.diagnostic.message == "earlier")
        #expect(controller.previousDiagnostic()?.diagnostic.message == "later")

        controller.setConfigDiagnostics(
            [earlier],
            owner: owner,
            contentRevision: 1
        )
        #expect(controller.selectedDiagnostic == nil)
    }

    @Test("Severity and source filters constrain rows and keyboard navigation")
    func filtersConstrainRowsAndNavigation() throws {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }
        let owner = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/a.yml"
        )
        states = [state(owner, revision: 1)]
        controller.setConfigDiagnostics(
            [
                makeDiagnostic(
                    line: 1,
                    message: "error",
                    severity: .error,
                    source: "yamllint"
                ),
                makeDiagnostic(
                    line: 2,
                    message: "warning",
                    severity: .warning,
                    source: "schema"
                )
            ],
            owner: owner,
            contentRevision: 1
        )

        #expect(controller.availableSources == ["schema", "yamllint"])
        controller.severityFilter = .warning
        #expect(
            controller.groupedDiagnostics.flatMap(\.diagnostics)
                .map(\.diagnostic.message) == ["warning"]
        )
        #expect(controller.nextDiagnostic()?.diagnostic.message == "warning")

        controller.severityFilter = .all
        controller.sourceFilter = "yamllint"
        #expect(
            controller.groupedDiagnostics.flatMap(\.diagnostics)
                .map(\.diagnostic.message) == ["error"]
        )
        #expect(controller.previousDiagnostic()?.diagnostic.message == "error")
    }

    @Test("Problems distinguishes empty, unsupported, and disabled states")
    func presentationStatesAreDistinct() {
        var states: [ProblemsDocumentState] = []
        let controller = ProblemsPanelController()
        controller.configureDocumentStatesProvider { states }
        #expect(controller.presentationState == .empty)

        let unsupported = controller.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/notes.txt"
        )
        states = [state(unsupported, revision: 0)]
        #expect(controller.presentationState == .unsupported)

        let defaultsName = "ProblemsPanel-disabled-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            Issue.record("Failed to create isolated defaults")
            return
        }
        defaults.removePersistentDomain(forName: defaultsName)
        let settings = LSPSettings(defaults: defaults)
        settings.setEnabled(false)
        let manager = LSPManager(settings: settings)
        let disabledController = ProblemsPanelController(lspManager: manager)
        let swiftOwner = disabledController.documentOwner(
            paneID: PaneID(),
            tabID: UUID(),
            uri: "file:///project/App.swift"
        )
        disabledController.configureDocumentStatesProvider {
            [state(swiftOwner, revision: 0)]
        }
        #expect(disabledController.presentationState == .disabled)
    }

    @Test("Project navigation focuses the owning pane and keeps the column")
    func projectNavigationUsesOwningPane() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-problems-routing-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first.yml")
        let secondURL = directory.appendingPathComponent("second.yml")
        try "first: value".write(
            to: firstURL,
            atomically: true,
            encoding: .utf8
        )
        try "second: value".write(
            to: secondURL,
            atomically: true,
            encoding: .utf8
        )

        let project = ProjectManager()
        let firstPane = project.paneManager.activePaneID
        let firstTabs = try #require(
            project.paneManager.tabManager(for: firstPane)
        )
        firstTabs.openTab(url: firstURL)
        let firstTab = try #require(firstTabs.activeTab)
        let owner = project.problemsController.documentOwner(
            paneID: firstPane,
            tabID: firstTab.id,
            uri: firstURL.absoluteString
        )
        project.problemsController.setConfigDiagnostics(
            [makeDiagnostic(line: 1, column: 8)],
            owner: owner,
            contentRevision: firstTab.contentVersion
        )
        let entry = try #require(
            project.problemsController.flatDiagnostics.only
        )

        let secondPane = try #require(
            project.paneManager.splitPane(
                firstPane,
                axis: .horizontal
            )
        )
        let secondTabs = try #require(
            project.paneManager.tabManager(for: secondPane)
        )
        secondTabs.openTab(url: secondURL)
        #expect(project.paneManager.activePaneID == secondPane)

        #expect(project.navigateToProblem(entry))
        #expect(project.paneManager.activePaneID == firstPane)
        #expect(
            firstTabs.pendingGoToLocation
                == EditorNavigationLocation(line: 1, column: 8)
        )
        #expect(secondTabs.pendingGoToLocation == nil)

        firstTabs.updateContent("first: changed")
        #expect(!project.navigateToProblem(entry))
    }

    @Test("Config validator publishes identical empty results for each revision")
    func configValidatorResultGenerationTracksRevision() {
        let validator = ConfigValidator()
        let unsupported = URL(fileURLWithPath: "/tmp/plain.txt")

        validator.validate(
            url: unsupported,
            content: "one",
            revision: 1
        )
        let firstGeneration = validator.diagnosticsResultGeneration
        #expect(validator.diagnosticsRevision == 1)
        #expect(validator.diagnostics.isEmpty)

        validator.validate(
            url: unsupported,
            content: "two",
            revision: 2
        )
        #expect(validator.diagnosticsResultGeneration > firstGeneration)
        #expect(validator.diagnosticsRevision == 2)
        #expect(validator.diagnostics.isEmpty)
    }

    @Test("Tab navigation keeps line and column atomic")
    func tabNavigationPreservesColumn() {
        let manager = TabManager()
        manager.pendingGoToLocation = EditorNavigationLocation(
            line: 7,
            column: 12
        )
        #expect(manager.pendingGoToLine == 7)
        #expect(manager.pendingGoToLocation?.column == 12)

        manager.pendingGoToLine = 3
        #expect(
            manager.pendingGoToLocation
                == EditorNavigationLocation(line: 3, column: nil)
        )
    }

    private func state(
        _ owner: ProblemsDocumentOwner,
        revision: UInt64,
        focused: Bool = false
    ) -> ProblemsDocumentState {
        ProblemsDocumentState(
            owner: owner,
            contentRevision: revision,
            isFocusedPane: focused
        )
    }

    private func makeDiagnostic(
        line: Int = 1,
        column: Int? = nil,
        message: String = "problem",
        severity: ValidationSeverity = .error,
        source: String = "validator"
    ) -> ValidationDiagnostic {
        ValidationDiagnostic(
            line: line,
            column: column,
            message: message,
            severity: severity,
            source: source
        )
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
