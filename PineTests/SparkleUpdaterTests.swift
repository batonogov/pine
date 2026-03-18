//
//  SparkleUpdaterTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct SparkleUpdaterTests {

    @Test func appcastURLIsValid() {
        let urlString = SparkleConstants.appcastURLString
        #expect(urlString == "https://github.com/batonogov/pine/releases/latest/download/appcast.xml")
        #expect(URL(string: urlString) != nil)
    }
}
