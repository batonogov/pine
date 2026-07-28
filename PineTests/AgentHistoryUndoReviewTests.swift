//
//  AgentHistoryUndoReviewTests.swift
//  PineTests
//
//  Security, state-machine, content-projection, payload, and localization
//  coverage for verified Agent History undo review (#1276).
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("Agent History Undo Review", .serialized)
struct AgentHistoryUndoReviewTests {
    @Test("Apply activation is exactly once and dismissal stays locked")
    func exactlyOnceActionGate() throws {
        let model = AgentHistoryUndoPreviewModel(
            historyEntryID: UUID(),
            operations: []
        )
        var gate = AgentHistoryUndoReviewActionGate()
        gate.finishPreparation(.available(model))

        #expect(gate.phase == .ready)
        #expect(gate.canApply)
        #expect(gate.canDismiss)
        let firstActivation = gate.beginApply()
        let duplicateActivation = gate.beginApply()
        #expect(firstActivation)
        #expect(!duplicateActivation)
        #expect(gate.phase == .revalidating)
        #expect(!gate.canApply)
        #expect(!gate.canDismiss)

        let acceptedValidation = gate.finishRevalidation(
            .available(model)
        )
        #expect(acceptedValidation)
        #expect(gate.phase == .applying)
        let duplicateValidation = gate.finishRevalidation(
            .available(model)
        )
        #expect(!duplicateValidation)
        #expect(!gate.canDismiss)

        gate.finishApply()
        #expect(gate.phase == .finished)
        #expect(gate.canDismiss)
        let activationAfterFinish = gate.beginApply()
        #expect(!activationAfterFinish)
    }

    @Test("Cancel leaves a ready review inert and stale validation is terminal")
    func cancelAndStaleStates() {
        let model = AgentHistoryUndoPreviewModel(
            historyEntryID: UUID(),
            operations: []
        )
        var cancelled = AgentHistoryUndoReviewActionGate()
        cancelled.finishPreparation(.available(model))
        #expect(cancelled.phase == .ready)
        #expect(cancelled.canDismiss)

        var stale = cancelled
        let staleActivation = stale.beginApply()
        let staleValidation = stale.finishRevalidation(
            .unavailable(.currentContentDiverged(path: "App.swift"))
        )
        #expect(staleActivation)
        #expect(!staleValidation)
        #expect(
            stale.phase
                == .blocked(.currentContentDiverged(path: "App.swift"))
        )
        #expect(stale.canDismiss)
        #expect(!stale.canApply)
    }

    @Test("Payload validator reports every anomalous binding")
    func payloadAnomalies() throws {
        let path = "App.swift"
        let before = Data("before\n".utf8)
        let after = Data("after\n".utf8)
        let change = modifyChange(path: path, before: before, after: after)
        let changeSet = makeChangeSet(changes: [change])
        let validEntry = AgentHistoryInverseFileEntry(
            relativePath: path,
            operation: .modify,
            beforeContent: before,
            permissions: 0o644
        )

        expectFailure(
            .unsupportedFormatVersion(99),
            changeSet: changeSet,
            payload: AgentHistoryInversePayload(
                formatVersion: 99,
                entries: [validEntry]
            )
        )
        expectFailure(
            .entryCountMismatch(expected: 1, actual: 0),
            changeSet: changeSet,
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: []
            )
        )
        expectFailure(
            .unexpectedPath("Other.swift"),
            changeSet: changeSet,
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [
                    AgentHistoryInverseFileEntry(
                        relativePath: "Other.swift",
                        operation: .modify,
                        beforeContent: before,
                        permissions: 0o644
                    )
                ]
            )
        )
        expectFailure(
            .operationMismatch(path),
            changeSet: changeSet,
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [
                    AgentHistoryInverseFileEntry(
                        relativePath: path,
                        operation: .create,
                        beforeContent: nil,
                        permissions: nil
                    )
                ]
            )
        )
        expectFailure(
            .missingBeforeContent(path),
            changeSet: changeSet,
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [
                    AgentHistoryInverseFileEntry(
                        relativePath: path,
                        operation: .modify,
                        beforeContent: nil,
                        permissions: 0o644
                    )
                ]
            )
        )
        expectFailure(
            .permissionMismatch(path),
            changeSet: changeSet,
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [
                    AgentHistoryInverseFileEntry(
                        relativePath: path,
                        operation: .modify,
                        beforeContent: before,
                        permissions: 0o600
                    )
                ]
            )
        )
        expectFailure(
            .byteCountMismatch(path),
            changeSet: makeChangeSet(changes: [
                AgentHistoryRecordedFileChange(
                    relativePath: path,
                    operation: .modify,
                    before: AgentHistoryRecordedFileState(
                        kind: .regularFile,
                        contentSHA256:
                            AgentHistoryContentHash.sha256Hex(before),
                        byteCount: UInt64(before.count + 1),
                        permissions: 0o644
                    ),
                    after: state(after)
                )
            ]),
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [validEntry]
            )
        )
        expectFailure(
            .contentHashMismatch(path),
            changeSet: makeChangeSet(changes: [
                AgentHistoryRecordedFileChange(
                    relativePath: path,
                    operation: .modify,
                    before: AgentHistoryRecordedFileState(
                        kind: .regularFile,
                        contentSHA256: String(repeating: "a", count: 64),
                        byteCount: UInt64(before.count),
                        permissions: 0o644
                    ),
                    after: state(after)
                )
            ]),
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [validEntry]
            )
        )

        let secondChange = modifyChange(
            path: "Other.swift",
            before: before,
            after: after
        )
        expectFailure(
            .duplicatePath(path),
            changeSet: makeChangeSet(changes: [change, secondChange]),
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [validEntry, validEntry]
            )
        )

        let createPath = "Created.swift"
        let createChange = AgentHistoryRecordedFileChange(
            relativePath: createPath,
            operation: .create,
            before: nil,
            after: state(after)
        )
        expectFailure(
            .unexpectedBeforeContent(createPath),
            changeSet: makeChangeSet(changes: [createChange]),
            payload: AgentHistoryInversePayload(
                formatVersion: 1,
                entries: [
                    AgentHistoryInverseFileEntry(
                        relativePath: createPath,
                        operation: .create,
                        beforeContent: before,
                        permissions: nil
                    )
                ]
            )
        )
    }

    @Test("Preview distinguishes text, binary, omitted, create, and delete")
    func contentRepresentationsAndLineEndings() throws {
        let textBefore = Data("restored\r\nno newline".utf8)
        let textAfter = Data("current\n".utf8)
        let binaryBefore = Data([0xFF, 0x00])
        let binaryAfter = Data([0xFE, 0x00])
        let largeBefore = Data(
            String(repeating: "before\n", count: 2_001).utf8
        )
        let largeAfter = Data(
            String(repeating: "after\n", count: 2_001).utf8
        )
        let created = Data("created\n".utf8)
        let deleted = Data("deleted\n".utf8)

        let changes = [
            modifyChange(
                path: "Text.txt",
                before: textBefore,
                after: textAfter
            ),
            modifyChange(
                path: "Binary.dat",
                before: binaryBefore,
                after: binaryAfter
            ),
            modifyChange(
                path: "Large.txt",
                before: largeBefore,
                after: largeAfter
            ),
            AgentHistoryRecordedFileChange(
                relativePath: "Created.txt",
                operation: .create,
                before: nil,
                after: state(created)
            ),
            AgentHistoryRecordedFileChange(
                relativePath: "Deleted.txt",
                operation: .delete,
                before: state(deleted),
                after: nil
            )
        ]
        let changeSet = makeChangeSet(changes: changes)
        let payload = AgentHistoryInversePayload(
            formatVersion: 1,
            entries: [
                inverseModify("Text.txt", textBefore),
                inverseModify("Binary.dat", binaryBefore),
                inverseModify("Large.txt", largeBefore),
                AgentHistoryInverseFileEntry(
                    relativePath: "Created.txt",
                    operation: .create,
                    beforeContent: nil,
                    permissions: nil
                ),
                AgentHistoryInverseFileEntry(
                    relativePath: "Deleted.txt",
                    operation: .delete,
                    beforeContent: deleted,
                    permissions: 0o644
                )
            ]
        )
        let validated = try AgentHistoryInversePayloadValidator.validate(
            changeSet: changeSet,
            payload: payload
        ).get()
        let snapshots = [
            snapshot("Text.txt", textAfter),
            snapshot("Binary.dat", binaryAfter),
            snapshot("Large.txt", largeAfter),
            snapshot("Created.txt", created),
            snapshot("Deleted.txt", nil)
        ]
        let entry = makeEntry(changeSet: changeSet)
        let model = try #require(AgentHistoryUndoPreview.buildModel(
            entry: entry,
            changeSet: changeSet,
            payload: validated,
            snapshots: snapshots
        ))
        let operations = Dictionary(
            uniqueKeysWithValues: model.operations.map {
                ($0.relativePath, $0)
            }
        )

        let text = try #require(operations["Text.txt"])
        #expect(text.contentRepresentation == .textual)
        let endings = Set(
            text.hunks.flatMap(\.lines).map(\.lineEnding)
        )
        #expect(endings == [.lf, .crlf, .noFinalNewline])
        #expect(
            operations["Binary.dat"]?.contentRepresentation == .binary
        )
        #expect(operations["Binary.dat"]?.hunks.isEmpty == true)
        #expect(
            operations["Large.txt"]?.contentRepresentation == .omitted
        )
        #expect(
            operations["Created.txt"]?.contentRepresentation
                == .wholeFileRemoval
        )
        #expect(
            operations["Deleted.txt"]?.contentRepresentation
                == .wholeFileRestore
        )
    }

    @Test("Validated preview snapshots never reopen a swapped leaf")
    func immutableDescriptorSnapshotSurvivesPostReadSwap() throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let expected = Data("expected\n".utf8)
        let outside = Data("outside secret\n".utf8)
        try expected.write(to: fixture.url("App.swift"))
        try outside.write(to: fixture.outsideFile)
        let change = AgentHistoryRecordedFileChange(
            relativePath: "App.swift",
            operation: .modify,
            before: state(Data("before\n".utf8)),
            after: state(expected)
        )

        let result = AgentHistoryUndoPreview.validatedCurrentSnapshots(
            changes: [change],
            root: fixture.root,
            expectedRootDevice: fixture.rootIdentity.device,
            expectedRootInode: fixture.rootIdentity.inode,
            hooks: AgentHistoryUndoPreviewHooks(afterSnapshot: { _ in
                try? FileManager.default.removeItem(
                    at: fixture.url("App.swift")
                )
                try? FileManager.default.createSymbolicLink(
                    at: fixture.url("App.swift"),
                    withDestinationURL: fixture.outsideFile
                )
            })
        )
        let snapshots = try result.get()
        #expect(snapshots.count == 1)
        #expect(snapshots[0].data == expected)
        #expect(snapshots[0].data != outside)
    }

    @Test("Leaf and ancestor symlink swaps fail closed")
    func symlinkSwapsFailClosed() throws {
        let leafFixture = try WorkspaceFixture()
        defer { leafFixture.cleanup() }
        let expected = Data("expected\n".utf8)
        try expected.write(to: leafFixture.url("App.swift"))
        try Data("outside\n".utf8).write(to: leafFixture.outsideFile)
        let leafChange = AgentHistoryRecordedFileChange(
            relativePath: "App.swift",
            operation: .modify,
            before: state(Data("before\n".utf8)),
            after: state(expected)
        )
        let leafResult = AgentHistoryUndoPreview.validatedCurrentSnapshots(
            changes: [leafChange],
            root: leafFixture.root,
            expectedRootDevice: leafFixture.rootIdentity.device,
            expectedRootInode: leafFixture.rootIdentity.inode,
            hooks: AgentHistoryUndoPreviewHooks(beforeSnapshot: { _ in
                try? FileManager.default.removeItem(
                    at: leafFixture.url("App.swift")
                )
                try? FileManager.default.createSymbolicLink(
                    at: leafFixture.url("App.swift"),
                    withDestinationURL: leafFixture.outsideFile
                )
            })
        )
        #expect(
            failure(leafResult)
                == .currentContentDiverged(path: "App.swift")
        )

        let ancestorFixture = try WorkspaceFixture()
        defer { ancestorFixture.cleanup() }
        let directory = ancestorFixture.url("Sources")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try expected.write(
            to: directory.appendingPathComponent("App.swift")
        )
        let outsideDirectory = ancestorFixture.outsideFile
            .deletingLastPathComponent()
            .appendingPathComponent("outside-directory")
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: false
        )
        try expected.write(
            to: outsideDirectory.appendingPathComponent("App.swift")
        )
        let ancestorChange = AgentHistoryRecordedFileChange(
            relativePath: "Sources/App.swift",
            operation: .modify,
            before: state(Data("before\n".utf8)),
            after: state(expected)
        )
        let ancestorResult =
            AgentHistoryUndoPreview.validatedCurrentSnapshots(
                changes: [ancestorChange],
                root: ancestorFixture.root,
                expectedRootDevice: ancestorFixture.rootIdentity.device,
                expectedRootInode: ancestorFixture.rootIdentity.inode,
                hooks: AgentHistoryUndoPreviewHooks(
                    beforeSnapshot: { _ in
                        try? FileManager.default.removeItem(at: directory)
                        try? FileManager.default.createSymbolicLink(
                            at: directory,
                            withDestinationURL: outsideDirectory
                        )
                    }
                )
            )
        #expect(
            failure(ancestorResult)
                == .currentContentDiverged(path: "Sources/App.swift")
        )
    }

    @Test("FIFO and deletion or recreation races fail closed")
    func specialFileAndExistenceRacesFailClosed() throws {
        let fifoFixture = try WorkspaceFixture()
        defer { fifoFixture.cleanup() }
        let expected = Data("expected\n".utf8)
        try expected.write(to: fifoFixture.url("App.swift"))
        let modify = AgentHistoryRecordedFileChange(
            relativePath: "App.swift",
            operation: .modify,
            before: state(Data("before\n".utf8)),
            after: state(expected)
        )
        let fifoPath = fifoFixture.url("App.swift").path
        let fifoResult = AgentHistoryUndoPreview.validatedCurrentSnapshots(
            changes: [modify],
            root: fifoFixture.root,
            expectedRootDevice: fifoFixture.rootIdentity.device,
            expectedRootInode: fifoFixture.rootIdentity.inode,
            hooks: AgentHistoryUndoPreviewHooks(beforeSnapshot: { _ in
                try? FileManager.default.removeItem(
                    at: fifoFixture.url("App.swift")
                )
                _ = mkfifo(fifoPath, 0o600)
            })
        )
        #expect(
            failure(fifoResult)
                == .currentContentDiverged(path: "App.swift")
        )

        let missingFixture = try WorkspaceFixture()
        defer { missingFixture.cleanup() }
        try expected.write(to: missingFixture.url("Created.swift"))
        let create = AgentHistoryRecordedFileChange(
            relativePath: "Created.swift",
            operation: .create,
            before: nil,
            after: state(expected)
        )
        let removedResult =
            AgentHistoryUndoPreview.validatedCurrentSnapshots(
                changes: [create],
                root: missingFixture.root,
                expectedRootDevice: missingFixture.rootIdentity.device,
                expectedRootInode: missingFixture.rootIdentity.inode,
                hooks: AgentHistoryUndoPreviewHooks(
                    beforeSnapshot: { _ in
                        try? FileManager.default.removeItem(
                            at: missingFixture.url("Created.swift")
                        )
                    }
                )
            )
        #expect(
            failure(removedResult)
                == .currentContentDiverged(path: "Created.swift")
        )

        let delete = AgentHistoryRecordedFileChange(
            relativePath: "Deleted.swift",
            operation: .delete,
            before: state(expected),
            after: nil
        )
        let recreatedResult =
            AgentHistoryUndoPreview.validatedCurrentSnapshots(
                changes: [delete],
                root: missingFixture.root,
                expectedRootDevice: missingFixture.rootIdentity.device,
                expectedRootInode: missingFixture.rootIdentity.inode,
                hooks: AgentHistoryUndoPreviewHooks(
                    beforeSnapshot: { _ in
                        try? expected.write(
                            to: missingFixture.url("Deleted.swift")
                        )
                    }
                )
            )
        #expect(
            failure(recreatedResult)
                == .currentContentDiverged(path: "Deleted.swift")
        )
    }

    @Test("Localized path interpolation and file pluralization are formatted")
    @MainActor
    func localizedFormatting() {
        let path = "Sources/App.swift"
        for identifier in [
            "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"
        ] {
            let locale = Locale(identifier: identifier)
            let message = Strings.undoFailContentDiverged(
                path,
                locale: locale
            )
            #expect(message.contains(path))
            #expect(!message.contains("\\("))
            let one = Strings.agentHistoryUndoReviewSummary(
                fileCount: 1,
                addedLineCount: 2,
                removedLineCount: 3,
                locale: locale
            )
            let many = Strings.agentHistoryUndoReviewSummary(
                fileCount: 5,
                addedLineCount: 2,
                removedLineCount: 3,
                locale: locale
            )
            #expect(one.contains("1"))
            #expect(many.contains("5"))
            #expect(one.contains("+2"))
            #expect(many.contains("−3"))
        }
    }

    @Test("Explicit locale selects failure, next-step, and recovery resources")
    @MainActor
    func explicitLocaleResolution() {
        let expectations = [
            (
                locale: "en",
                entryNotFound:
                    "This history entry no longer exists.",
                explanation:
                    "The workspace root, HEAD, or Git index changed after capture.",
                diverged:
                    "The current file no longer matches the verified snapshot: /safe/file",
                nextClose:
                    "Close this review.",
                nextNoAction:
                    "No files were changed. Keep the current workspace and close this review.",
                next:
                    "Close this review and inspect the current workspace state.",
                nextManual:
                    "Keep the current file and review its changes manually.",
                cancel: "Cancel",
                close: "Close",
                backup: "Recovery backup: /safe/backup",
                retained: "Retained recovery file: /safe/file"
            ),
            (
                locale: "ru",
                entryNotFound:
                    "Эта запись истории больше не существует.",
                explanation:
                    "После снимка изменились корень рабочей области, HEAD или индекс Git.",
                diverged:
                    "Текущий файл больше не совпадает с проверенным снимком: /safe/file",
                nextClose:
                    "Закройте это окно проверки.",
                nextNoAction:
                    "Файлы не изменены. Сохраните текущее состояние рабочей области и закройте проверку.",
                next:
                    "Закройте проверку и изучите текущее состояние рабочей области.",
                nextManual:
                    "Сохраните текущий файл и проверьте его изменения вручную.",
                cancel: "Отмена",
                close: "Закрыть",
                backup:
                    "Резервная копия для восстановления: /safe/backup",
                retained:
                    "Сохранённый файл восстановления: /safe/file"
            ),
            (
                locale: "ja",
                entryNotFound:
                    "この履歴項目は存在しません。",
                explanation:
                    "取得後にワークスペースルート、HEAD、または Git インデックスが変更されました。",
                diverged:
                    "現在のファイルが検証済みスナップショットと一致しません: /safe/file",
                nextClose:
                    "この確認画面を閉じてください。",
                nextNoAction:
                    "ファイルは変更されていません。現在のワークスペースを保持して、この確認画面を閉じてください。",
                next:
                    "この確認画面を閉じて、現在のワークスペース状態を確認してください。",
                nextManual:
                    "現在のファイルを保持し、変更を手動で確認してください。",
                cancel: "キャンセル",
                close: "閉じる",
                backup: "復旧用バックアップ: /safe/backup",
                retained: "保持された復旧ファイル: /safe/file"
            ),
        ]

        for expectation in expectations {
            let locale = Locale(identifier: expectation.locale)
            let failure = AgentHistoryUndoPreviewFailure.workspaceChanged
            #expect(
                AgentHistoryUndoPreviewFailure.entryNotFound.explanation(
                    locale: locale
                ) == expectation.entryNotFound
            )
            #expect(
                failure.explanation(locale: locale)
                    == expectation.explanation
            )
            #expect(
                AgentHistoryUndoPreviewFailure.currentContentDiverged(
                    path: "/safe/file"
                ).explanation(locale: locale) == expectation.diverged
            )
            #expect(
                AgentHistoryUndoPreviewFailure.entryNotFound.nextAction(
                    locale: locale
                ) == expectation.nextClose
            )
            #expect(
                AgentHistoryUndoPreviewFailure.notEligible.nextAction(
                    locale: locale
                ) == expectation.nextNoAction
            )
            #expect(failure.nextAction(locale: locale) == expectation.next)
            #expect(
                AgentHistoryUndoPreviewFailure.currentContentDiverged(
                    path: "/safe/file"
                ).nextAction(locale: locale) == expectation.nextManual
            )
            #expect(
                Strings.dialogCancel(locale: locale) == expectation.cancel
            )
            #expect(
                Strings.dialogClose(locale: locale) == expectation.close
            )
            #expect(
                Strings.agentHistoryRecoveryBackup(
                    "/safe/backup",
                    locale: locale
                ) == expectation.backup
            )
            #expect(
                Strings.agentHistoryRetainedRecoveryFile(
                    "/safe/file",
                    locale: locale
                ) == expectation.retained
            )
        }
    }

    @Test("Every undo-review key is translated in all supported locales")
    func localizationCoverage() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let catalogURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        let strings = try #require(
            root["strings"] as? [String: Any]
        )
        let expectedLocales = Set([
            "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"
        ])
        let keys = [
            "agentHistory.reviewChangesButton",
            "agentHistory.undoReview.title",
            "agentHistory.undoReview.preparing",
            "agentHistory.undoReview.verified",
            "agentHistory.undoReview.technicalDetails",
            "agentHistory.undoReview.apply",
            "agentHistory.undoReview.revalidated",
            "agentHistory.undoReview.staleTitle",
            "agentHistory.undoReview.content.binary",
            "agentHistory.undoReview.content.omitted",
            "agentHistory.undoReview.failure.entryNotFound",
            "agentHistory.undoReview.failure.alreadyReverted",
            "agentHistory.undoReview.failure.notEligible",
            "agentHistory.undoReview.failure.authorityMissing",
            "agentHistory.undoReview.failure.authorityConsumed",
            "agentHistory.undoReview.failure.workspaceChanged",
            "agentHistory.undoReview.failure.projectionTampered",
            "agentHistory.undoReview.failure.payloadMissing",
            "agentHistory.undoReview.failure.payloadInvalid",
            "agentHistory.undoReview.failure.contentDiverged %@",
            "agentHistory.undoReview.failure.previewFailed",
            "agentHistory.undoReview.next.close",
            "agentHistory.undoReview.next.noAction",
            "agentHistory.undoReview.next.refresh",
            "agentHistory.undoReview.next.manualReview",
            "agentHistory.recoveryBackup %@",
            "agentHistory.retainedRecoveryFile %@"
        ]
        for key in keys {
            let value = try #require(strings[key] as? [String: Any])
            let localizations = try #require(
                value["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == expectedLocales)
            for locale in expectedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                #expect(unit["state"] as? String == "translated")
                #expect(!(unit["value"] as? String ?? "").isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private func expectFailure(
        _ expected: AgentHistoryPayloadFailure,
        changeSet: VerifiedAgentChangeSet,
        payload: AgentHistoryInversePayload
    ) {
        switch AgentHistoryInversePayloadValidator.validate(
            changeSet: changeSet,
            payload: payload
        ) {
        case .success:
            Issue.record("Payload unexpectedly validated")
        case .failure(let actual):
            #expect(actual == expected)
        }
    }

    private func failure(
        _ result: Result<
            [AgentHistorySafeFileSnapshot],
            AgentHistoryUndoPreviewFailure
        >
    ) -> AgentHistoryUndoPreviewFailure? {
        guard case .failure(let failure) = result else { return nil }
        return failure
    }

    private func inverseModify(
        _ path: String,
        _ before: Data
    ) -> AgentHistoryInverseFileEntry {
        AgentHistoryInverseFileEntry(
            relativePath: path,
            operation: .modify,
            beforeContent: before,
            permissions: 0o644
        )
    }

    private func snapshot(
        _ path: String,
        _ data: Data?
    ) -> AgentHistorySafeFileSnapshot {
        AgentHistorySafeFileSnapshot(
            relativePath: path,
            data: data,
            permissions: data == nil ? nil : 0o644,
            device: data == nil ? nil : 1,
            inode: data == nil ? nil : 1
        )
    }

    private func modifyChange(
        path: String,
        before: Data,
        after: Data
    ) -> AgentHistoryRecordedFileChange {
        AgentHistoryRecordedFileChange(
            relativePath: path,
            operation: .modify,
            before: state(before),
            after: state(after)
        )
    }

    private func state(
        _ data: Data
    ) -> AgentHistoryRecordedFileState {
        AgentHistoryRecordedFileState(
            kind: .regularFile,
            contentSHA256: AgentHistoryContentHash.sha256Hex(data),
            byteCount: UInt64(data.count),
            permissions: 0o644
        )
    }

    private func makeEntry(
        changeSet: VerifiedAgentChangeSet
    ) -> AgentHistoryEntry {
        AgentHistoryEntry(
            id: changeSet.historyEntryID,
            sessionID: changeSet.provenance.sessionID,
            agentTypeRaw: "codex",
            startedAt: Date(),
            endedAt: Date(),
            affectedFiles: changeSet.changes.map(\.relativePath),
            attribution: .verified,
            verifiedChangeSet: changeSet,
            summary: "test"
        )
    }

    private func makeChangeSet(
        changes: [AgentHistoryRecordedFileChange]
    ) -> VerifiedAgentChangeSet {
        let historyEntryID = UUID()
        let sessionID = UUID()
        return VerifiedAgentChangeSet(
            id: UUID(),
            historyEntryID: historyEntryID,
            schemaVersion: VerifiedAgentChangeSet.currentSchemaVersion,
            capturedAt: Date(),
            provenance: AgentHistoryWriterProvenance(
                sessionID: sessionID,
                writerInstanceID: UUID(),
                processIdentifier: 123,
                processGeneration: 1,
                firstEventSequence: 1,
                lastEventSequence: 2
            ),
            workspace: AgentHistoryWorkspaceIdentity(
                privateWorkspaceID: UUID(),
                headOID: String(repeating: "a", count: 40),
                indexSHA256: String(repeating: "b", count: 64)
            ),
            changes: changes,
            authority: AgentHistoryPrivateAuthorityReference(
                storage: .applicationSupport,
                recordID: UUID(),
                manifestFormatVersion:
                    AgentHistoryPrivateAuthorityReference
                    .currentManifestFormatVersion,
                canonicalContractSHA256:
                    String(repeating: "c", count: 64)
            ),
            inversePayload: AgentHistoryInversePayloadReference(
                storage: .applicationSupport,
                blobID: UUID(),
                formatVersion:
                    AgentHistoryInversePayloadReference.currentFormatVersion,
                byteCount: 1,
                sha256: String(repeating: "d", count: 64)
            )
        )
    }

    nonisolated private final class WorkspaceFixture:
        @unchecked Sendable {
        let root: URL
        let outsideFile: URL
        let rootIdentity: (device: UInt64, inode: UInt64)

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "pine-undo-preview-\(UUID().uuidString)",
                    isDirectory: true
                )
            outsideFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "pine-undo-preview-outside-\(UUID().uuidString)",
                    isDirectory: false
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
            rootIdentity = try #require(
                AgentHistoryContentHash.rootIdentity(root)
            )
        }

        func url(_ path: String) -> URL {
            root.appendingPathComponent(path)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outsideFile)
            try? FileManager.default.removeItem(
                at: outsideFile
                    .deletingLastPathComponent()
                    .appendingPathComponent("outside-directory")
            )
        }
    }
}
