//
//  CompletionFilterTests.swift
//  PineTests
//
//  Unit tests for CompletionFilter — pure prefix-filter + ranker for LSP
//  completion items. Scoring: exact > prefix > word boundary > substring >
//  fuzzy subsequence.
//

import Foundation
import Testing

@testable import Pine

@Suite("CompletionFilter Tests")
struct CompletionFilterTests {

    // MARK: - Exact match (highest rank)

    @Test("Exact match ranks highest")
    func exactMatchRanksHighest() {
        let items = [
            LSPCompletionItem(label: "bar"),
            LSPCompletionItem(label: "foo"),
            LSPCompletionItem(label: "foobar"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result.first?.label == "foo")
    }

    @Test("Exact match is case insensitive")
    func exactMatchCaseInsensitive() {
        let items = [
            LSPCompletionItem(label: "Bar"),
            LSPCompletionItem(label: "FOO"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result.first?.label == "FOO")
    }

    // MARK: - Prefix match

    @Test("Prefix match ranks above substring")
    func prefixAboveSubstring() {
        let items = [
            LSPCompletionItem(label: "xfoo"),      // substring only
            LSPCompletionItem(label: "foobar"),    // prefix match
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result[0].label == "foobar")
        #expect(result[1].label == "xfoo")
    }

    // MARK: - Word boundary match

    @Test("Word boundary via underscore ranks above substring")
    func wordBoundaryUnderscore() {
        let items = [
            LSPCompletionItem(label: "xfoo"),      // substring
            LSPCompletionItem(label: "my_foo"),    // word boundary (_)
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result[0].label == "my_foo")
        #expect(result[1].label == "xfoo")
    }

    @Test("Word boundary via dash")
    func wordBoundaryDash() {
        let items = [
            LSPCompletionItem(label: "xfoo"),
            LSPCompletionItem(label: "my-foo"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result[0].label == "my-foo")
    }

    @Test("Word boundary via dot")
    func wordBoundaryDot() {
        let items = [
            LSPCompletionItem(label: "xfoo"),
            LSPCompletionItem(label: "obj.foo"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result[0].label == "obj.foo")
    }

    // MARK: - Substring match

    @Test("Substring match included when no prefix/boundary")
    func substringMatch() {
        let items = [
            LSPCompletionItem(label: "xfoobar"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result.count == 1)
        #expect(result[0].label == "xfoobar")
    }

    // MARK: - Fuzzy subsequence match

    @Test("Fuzzy subsequence match")
    func fuzzySubsequence() {
        let items = [
            LSPCompletionItem(label: "football"),
        ]
        // "ftl" is a subsequence of "football": f-o-o-t-b-a-l-l
        let result = CompletionFilter.filter(items, prefix: "ftl")
        #expect(result.count == 1)
    }

    @Test("Fuzzy ranks below substring")
    func fuzzyBelowSubstring() {
        let items = [
            LSPCompletionItem(label: "football"),  // fuzzy: "ftl" subsequence
            LSPCompletionItem(label: "aftl"),      // substring: contains "ftl"
        ]
        let result = CompletionFilter.filter(items, prefix: "ftl")
        #expect(result[0].label == "aftl")
        #expect(result[1].label == "football")
    }

    // MARK: - Non-match filtered out

    @Test("Non-matching items are filtered out")
    func nonMatchFiltered() {
        let items = [
            LSPCompletionItem(label: "foo"),
            LSPCompletionItem(label: "bar"),
            LSPCompletionItem(label: "baz"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result.count == 1)
    }

    // MARK: - Empty prefix

    @Test("Empty prefix returns all items in server order")
    func emptyPrefixReturnsAll() {
        let items = [
            LSPCompletionItem(label: "foo"),
            LSPCompletionItem(label: "bar"),
            LSPCompletionItem(label: "baz"),
        ]
        let result = CompletionFilter.filter(items, prefix: "")
        #expect(result.count == 3)
        #expect(result.map(\.label) == ["foo", "bar", "baz"])
    }

    @Test("Whitespace-only prefix returns all items")
    func whitespacePrefixReturnsAll() {
        let items = [
            LSPCompletionItem(label: "foo"),
            LSPCompletionItem(label: "bar"),
        ]
        let result = CompletionFilter.filter(items, prefix: "   ")
        #expect(result.count == 2)
    }

    // MARK: - Server order as tiebreaker

    @Test("Server order preserved for equal scores")
    func serverOrderPreserved() {
        let items = [
            LSPCompletionItem(label: "fooA"),
            LSPCompletionItem(label: "fooB"),
            LSPCompletionItem(label: "fooC"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        // All prefix-match with equal score — server order is the tiebreaker
        #expect(result.map(\.label) == ["fooA", "fooB", "fooC"])
    }

    // MARK: - filterText preference

    @Test("filterText used for matching when present")
    func filterTextUsedForMatching() {
        let items = [
            LSPCompletionItem(label: "displayLabel", filterText: "foo"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        #expect(result.count == 1)
    }

    @Test("filterText exact match ranks highest")
    func filterTextExactMatch() {
        let items = [
            LSPCompletionItem(label: "fooA"),
            LSPCompletionItem(label: "displayLabel", filterText: "foo"),
        ]
        let result = CompletionFilter.filter(items, prefix: "foo")
        // filterText "foo" exact-matches needle "foo" → score 10_000
        #expect(result[0].label == "displayLabel")
    }

    // MARK: - Full hierarchy ranking

    @Test("Full ranking hierarchy: exact > prefix > boundary > substring > fuzzy")
    func fullHierarchy() {
        let items = [
            LSPCompletionItem(label: "xfoobar"),       // substring
            LSPCompletionItem(label: "football"),       // fuzzy (ftl subsequence)
            LSPCompletionItem(label: "ftl"),            // exact
            LSPCompletionItem(label: "my_ftl"),         // word boundary
            LSPCompletionItem(label: "ftl_extra"),      // prefix
        ]
        let result = CompletionFilter.filter(items, prefix: "ftl")
        #expect(result.map(\.label) == ["ftl", "ftl_extra", "my_ftl", "xfoobar", "football"])
    }
}
