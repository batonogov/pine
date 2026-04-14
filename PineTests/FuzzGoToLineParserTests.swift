//
//  FuzzGoToLineParserTests.swift
//  PineTests
//
//  Fuzz tests for GoToLineParser input handling.
//

import Foundation
import Testing
@testable import Pine

@Suite("Fuzz Go To Line Parser Tests", .timeLimit(.minutes(1)))
struct FuzzGoToLineParserTests {

    @Test func fuzzGoToLineParser_randomInput() {
        var rng = SplitMix64(seed: 61)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 5 {
            case 0:
                input = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 100, rng: &rng), rng: &rng)
            case 1:
                input = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 50, rng: &rng), rng: &rng)
            case 2:
                input = "\(rng.next())"
            case 3:
                input = "\(rng.next()):\(rng.next())"
            default:
                input = ""
            }
            _ = GoToLineParser.parse(input)
        }
    }

    @Test func fuzzGoToLineParser_edgeCases() {
        let inputs = [
            "", " ", "\t", "\n", "\0",
            "0", "-1", "999999999999999999",
            "1:0", "0:1", "-1:-1",
            ":", "::", "1:", ":1",
            "abc", "1:abc", "abc:1",
            "1:1:1", "1:1:1:1",
            " 42 ", " 42 : 10 ",
            "\u{FEFF}1", "1\u{200B}",
        ]
        for input in inputs {
            _ = GoToLineParser.parse(input)
        }
    }
}
