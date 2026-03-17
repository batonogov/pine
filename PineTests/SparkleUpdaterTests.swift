//
//  SparkleUpdaterTests.swift
//  PineTests
//

import Sparkle
import Testing
import Foundation
@testable import Pine

@MainActor
struct SparkleUpdaterTests {

    @Test func updaterControllerIsInitialized() {
        let appDelegate = AppDelegate()
        let updater = appDelegate.updaterController.updater

        #expect(updater != nil)
    }

    @Test func appcastURLIsConfigured() {
        let expectedURL = "https://github.com/batonogov/pine/releases/latest/download/appcast.xml"
        #expect(SparkleConstants.appcastURLString == expectedURL)
    }
}
