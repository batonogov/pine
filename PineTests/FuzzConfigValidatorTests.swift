//
//  FuzzConfigValidatorTests.swift
//  PineTests
//
//  Fuzz tests for ValidatorOutputParser, BuiltinValidator, and ValidatorDetector.
//

import Foundation
import Testing
@testable import Pine

@Suite("Fuzz Config Validator Tests")
@MainActor
struct FuzzConfigValidatorTests {

    @Test func fuzzParseYamllint_randomInput() {
        var rng = SplitMix64(seed: 53)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomYamllintOutput(rng: &rng)
            case 2:
                input = FuzzGen.randomUnicode(
                    count: FuzzGen.randomLength(max: 200, rng: &rng),
                    rng: &rng
                )
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseYamllint(input)
        }
    }

    @Test func fuzzParseShellcheck_randomInput() {
        var rng = SplitMix64(seed: 54)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomShellcheckJSON(rng: &rng)
            case 2:
                input = "[]"
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseShellcheck(input)
        }
    }

    @Test func fuzzParseTerraform_randomInput() {
        var rng = SplitMix64(seed: 55)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomTerraformJSON(rng: &rng)
            case 2:
                input = "{\"valid\": true}"
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseTerraform(input)
        }
    }

    @Test func fuzzParseHadolint_randomInput() {
        var rng = SplitMix64(seed: 56)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomHadolintJSON(rng: &rng)
            case 2:
                input = "[]"
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseHadolint(input)
        }
    }

    @Test func fuzzBuiltinValidateYAML_randomInput() {
        var rng = SplitMix64(seed: 57)

        for _ in 0..<1000 {
            let content: String
            switch rng.next() % 4 {
            case 0:
                content = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 500, rng: &rng), rng: &rng)
            case 1:
                content = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 300, rng: &rng), rng: &rng)
            case 2:
                content = generateRandomYAML(rng: &rng)
            default:
                content = ""
            }
            _ = BuiltinValidator.validateYAML(content)
        }
    }

    @Test func fuzzBuiltinValidateDockerfile_randomInput() {
        var rng = SplitMix64(seed: 58)

        for _ in 0..<1000 {
            let content: String
            switch rng.next() % 4 {
            case 0:
                content = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 500, rng: &rng), rng: &rng)
            case 1:
                content = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 300, rng: &rng), rng: &rng)
            case 2:
                content = generateRandomDockerfile(rng: &rng)
            default:
                content = ""
            }
            _ = BuiltinValidator.validateDockerfile(content)
        }
    }

    @Test func fuzzBuiltinValidateShell_randomInput() {
        var rng = SplitMix64(seed: 59)

        for _ in 0..<1000 {
            let content: String
            switch rng.next() % 4 {
            case 0:
                content = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 500, rng: &rng), rng: &rng)
            case 1:
                content = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 300, rng: &rng), rng: &rng)
            case 2:
                content = generateRandomShellScript(rng: &rng)
            default:
                content = ""
            }
            _ = BuiltinValidator.validateShell(content)
        }
    }

    @Test func fuzzValidatorDetector_randomURLs() {
        var rng = SplitMix64(seed: 60)
        let extensions = ["yml", "yaml", "tf", "tfvars", "sh", "bash", "zsh", "txt", "", "swift", "py"]
        let names = ["Dockerfile", "Dockerfile.prod", "dockerfile", "README.md", "Makefile", ".yml"]

        for _ in 0..<1000 {
            let url: URL
            if rng.next() % 2 == 0 {
                let ext = extensions[Int(rng.next() % UInt64(extensions.count))]
                url = URL(fileURLWithPath: "/tmp/\(FuzzGen.randomPrintable(count: 10, rng: &rng)).\(ext)")
            } else {
                let name = names[Int(rng.next() % UInt64(names.count))]
                url = URL(fileURLWithPath: "/tmp/\(name)")
            }
            _ = ValidatorDetector.detect(for: url)
        }
    }

    // MARK: - Generators

    private func generateRandomYamllintOutput(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 20, rng: &rng)
        for _ in 0..<count {
            let lineNum = rng.next() % 1000
            let col = rng.next() % 100
            let level = rng.next() % 2 == 0 ? "error" : "warning"
            lines.append("file.yml:\(lineNum):\(col): [\(level)] \(FuzzGen.randomPrintable(count: 30, rng: &rng))")
        }
        return lines.joined(separator: "\n")
    }

    private func generateRandomShellcheckJSON(rng: inout SplitMix64) -> String {
        let count = FuzzGen.randomLength(min: 0, max: 10, rng: &rng)
        var items: [String] = []
        for _ in 0..<count {
            items.append("""
            {"line":\(rng.next() % 100),"column":\(rng.next() % 80),"level":"warning","message":"msg","code":\(rng.next() % 9999)}
            """)
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func generateRandomTerraformJSON(rng: inout SplitMix64) -> String {
        if rng.next() % 2 == 0 {
            return "{\"valid\":false,\"diagnostics\":[{\"severity\":\"error\",\"summary\":\"test\",\"detail\":null}]}"
        }
        return "{\"valid\":true,\"diagnostics\":[]}"
    }

    private func generateRandomHadolintJSON(rng: inout SplitMix64) -> String {
        let count = FuzzGen.randomLength(min: 0, max: 10, rng: &rng)
        var items: [String] = []
        for _ in 0..<count {
            items.append("""
            {"line":\(rng.next() % 100),"column":\(rng.next() % 80),"level":"warning","message":"msg","code":"DL\(rng.next() % 9999)"}
            """)
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func generateRandomYAML(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 30, rng: &rng)
        for _ in 0..<count {
            let indent = String(
                repeating: rng.next() % 2 == 0 ? "  " : "\t",
                count: Int(rng.next() % 5)
            )
            lines.append("\(indent)key: value")
        }
        return lines.joined(separator: "\n")
    }

    private func generateRandomDockerfile(rng: inout SplitMix64) -> String {
        let instructions = ["FROM", "RUN", "CMD", "COPY", "ADD", "INVALID", "from", "run"]
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 20, rng: &rng)
        for _ in 0..<count {
            let instr = instructions[Int(rng.next() % UInt64(instructions.count))]
            lines.append("\(instr) \(FuzzGen.randomPrintable(count: 20, rng: &rng))")
        }
        return lines.joined(separator: "\n")
    }

    private func generateRandomShellScript(rng: inout SplitMix64) -> String {
        var lines: [String] = ["#!/bin/bash"]
        let count = FuzzGen.randomLength(min: 1, max: 20, rng: &rng)
        for _ in 0..<count {
            switch rng.next() % 4 {
            case 0: lines.append("[ $VAR == \"test\" ]")
            case 1: lines.append("echo `hostname`")
            case 2: lines.append("echo $(date)")
            default: lines.append("# comment")
            }
        }
        return lines.joined(separator: "\n")
    }
}
