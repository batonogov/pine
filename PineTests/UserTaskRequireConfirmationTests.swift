//
//  UserTaskRequireConfirmationTests.swift
//  PineTests
//
//  Tests for the `requireConfirmation` property on UserTask and its
//  auto-detection from destructive command patterns (milestone #1088, item 4).
//

import Foundation
import Testing
@testable import Pine

@Suite("UserTask.requireConfirmation")
struct UserTaskRequireConfirmationTests {

    @Test("explicit requireConfirmation = true is respected")
    func explicitTrue() {
        let task = UserTask(id: "t1", label: "T", command: "echo hello", requireConfirmation: true)
        #expect(task.effectiveRequireConfirmation() == true)
    }

    @Test("explicit requireConfirmation = false overrides destructive detection")
    func explicitFalseOverridesDestructive() {
        let task = UserTask(id: "t1", label: "T", command: "rm temp.txt", requireConfirmation: false)
        #expect(task.effectiveRequireConfirmation() == false)
    }

    @Test("nil requireConfirmation auto-detects destructive commands")
    func autoDetectDestructive() {
        let destructive = UserTask(id: "t1", label: "T", command: "rm temp.txt")
        #expect(destructive.effectiveRequireConfirmation() == true)

        let benign = UserTask(id: "t2", label: "T2", command: "swiftlint --fix")
        #expect(benign.effectiveRequireConfirmation() == false)
    }

    @Test("default init has nil requireConfirmation")
    func defaultIsNil() {
        let task = UserTask(id: "t", label: "T", command: "echo hi")
        #expect(task.requireConfirmation == nil)
    }

    @Test("Codable round-trips requireConfirmation")
    func codableRoundTrip() throws {
        let original = UserTask(id: "t", label: "T", command: "echo hi", requireConfirmation: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserTask.self, from: data)
        #expect(decoded.requireConfirmation == true)
    }

    @Test("Decoding tasks.json without require_confirmation defaults to nil")
    func decodeMissingKey() throws {
        let json = """
        {"id":"t","label":"T","command":"echo hi","scope":"activeFile"}
        """
        let task = try JSONDecoder().decode(UserTask.self, from: json.data(using: .utf8)!)
        #expect(task.requireConfirmation == nil)
    }

    @Test("Decoding tasks.json with require_confirmation reads the value")
    func decodePresentKey() throws {
        let jsonTrue = """
        {"id":"t","label":"T","command":"echo hi","require_confirmation":true}
        """
        let taskTrue = try JSONDecoder().decode(UserTask.self, from: jsonTrue.data(using: .utf8)!)
        #expect(taskTrue.requireConfirmation == true)

        let jsonFalse = """
        {"id":"t","label":"T","command":"echo hi","require_confirmation":false}
        """
        let taskFalse = try JSONDecoder().decode(UserTask.self, from: jsonFalse.data(using: .utf8)!)
        #expect(taskFalse.requireConfirmation == false)
    }
}
