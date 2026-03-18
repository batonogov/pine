//
//  URLAbbreviatedPathTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("URL.abbreviatedPath Tests")
struct URLAbbreviatedPathTests {

    @Test func replacesHomeDirWithTilde() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: "\(home)/Documents/project")
        #expect(url.abbreviatedPath == "~/Documents/project")
    }

    @Test func leavesNonHomePathUnchanged() {
        let url = URL(fileURLWithPath: "/usr/local/bin")
        #expect(url.abbreviatedPath == "/usr/local/bin")
    }

    @Test func handlesHomeRootPath() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: home)
        #expect(url.abbreviatedPath == "~")
    }

    @Test func doesNotReplaceHomeDirSubstring() {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: "/other\(home)/project")
        #expect(url.abbreviatedPath == "/other\(home)/project")
    }
}
