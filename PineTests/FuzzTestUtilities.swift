//
//  FuzzTestUtilities.swift
//  PineTests
//
//  Shared utilities for fuzz tests: deterministic PRNG and random input generators.
//

import Foundation

// MARK: - Seed Registry
//
// Each fuzz test suite uses a unique seed range to avoid correlation.
// Seed  42–46: FuzzGitParserTests (diff=42, hunk=43, blame=44, status=45, ignored=46)
// Seed  47:    FuzzSyntaxHighlighterTests
// Seed  48–49: FuzzQuickOpenProviderTests (score=48, subseq=49)
// Seed  50–52: FuzzSymbolParserTests (parse=50, filter=51, lineNum=52)
// Seed  53–60: FuzzConfigValidatorTests (yamllint=53, shellcheck=54, terraform=55,
//              hadolint=56, builtinYAML=57, dockerfile=58, shell=59, detector=60)
// Seed  61:    FuzzGoToLineParserTests
//
// Next available seed: 62
//
// Iteration count: each random-input fuzz test runs 200 iterations. With the
// deterministic SplitMix64 PRNG this still exercises ample edge cases while
// keeping each suite well under the per-test time limit on shared CI runners.

// MARK: - Deterministic PRNG

/// SplitMix64 — fast, deterministic PRNG seeded once for reproducibility.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

// MARK: - Random Input Generators

/// Generates random strings of various kinds for fuzzing.
enum FuzzGen {

    /// Random bytes (full 0–255 range), decoded as UTF-8 with lossy fallback.
    static func randomBytes(count: Int, rng: inout SplitMix64) -> String {
        let bytes = (0..<count).map { _ in UInt8(rng.next() % 256) }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }

    /// Random printable ASCII string.
    static func randomPrintable(count: Int, rng: inout SplitMix64) -> String {
        let printable = Array(UInt8(32)...UInt8(126))
        return String((0..<count).map { _ in Character(UnicodeScalar(printable[Int(rng.next() % UInt64(printable.count))])) })
    }

    /// Random unicode string with emoji, CJK, combining marks, etc.
    static func randomUnicode(count: Int, rng: inout SplitMix64) -> String {
        let codePoints: [UInt32] = [
            0x0041, 0x00E9, 0x0410, 0x4E2D, 0x1F600, 0x1F4A9, 0x0300, 0x200B,
            0xFEFF, 0x000A, 0x000D, 0x0009, 0x0000, 0x007F, 0x2028, 0x2029,
            0x1F1FA, 0x1F1F8, 0xD7FF, 0xFFFD, 0x10FFFF
        ]
        var result = ""
        for _ in 0..<count {
            let cp = codePoints[Int(rng.next() % UInt64(codePoints.count))]
            if let scalar = UnicodeScalar(cp) {
                result.append(Character(scalar))
            }
        }
        return result
    }

    /// Random length between min and max.
    static func randomLength(min: Int = 0, max: Int = 500, rng: inout SplitMix64) -> Int {
        min + Int(rng.next() % UInt64(max - min + 1))
    }

    /// Random line ending.
    static func randomLineEnding(rng: inout SplitMix64) -> String {
        switch rng.next() % 3 {
        case 0: return "\n"
        case 1: return "\r\n"
        default: return "\r"
        }
    }
}
