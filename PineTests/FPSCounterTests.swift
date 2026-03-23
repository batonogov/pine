//
//  FPSCounterTests.swift
//  PineTests
//
//  Created by Claude on 23.03.2026.
//

import AppKit
import Testing

@testable import Pine

@Suite("FPSCounter Tests")
struct FPSCounterTests {

    // MARK: - FPSLevel from fps value

    @Test("Excellent level for 120 fps")
    func levelExcellentAt120() {
        #expect(FPSLevel(fps: 120) == .excellent)
    }

    @Test("Excellent level for 90 fps")
    func levelExcellentAt90() {
        #expect(FPSLevel(fps: 90) == .excellent)
    }

    @Test("Good level for 60 fps")
    func levelGoodAt60() {
        #expect(FPSLevel(fps: 60) == .good)
    }

    @Test("Good level for 50 fps")
    func levelGoodAt50() {
        #expect(FPSLevel(fps: 50) == .good)
    }

    @Test("Fair level for 30 fps")
    func levelFairAt30() {
        #expect(FPSLevel(fps: 30) == .fair)
    }

    @Test("Fair level for 45 fps")
    func levelFairAt45() {
        #expect(FPSLevel(fps: 45) == .fair)
    }

    @Test("Poor level for 29 fps")
    func levelPoorAt29() {
        #expect(FPSLevel(fps: 29) == .poor)
    }

    @Test("Poor level for 0 fps")
    func levelPoorAtZero() {
        #expect(FPSLevel(fps: 0) == .poor)
    }

    // MARK: - FPSLevel colors

    @Test("Excellent level is green")
    func excellentColorGreen() {
        #expect(FPSLevel.excellent.color == .systemGreen)
    }

    @Test("Good level is yellow")
    func goodColorYellow() {
        #expect(FPSLevel.good.color == .systemYellow)
    }

    @Test("Fair level is orange")
    func fairColorOrange() {
        #expect(FPSLevel.fair.color == .systemOrange)
    }

    @Test("Poor level is red")
    func poorColorRed() {
        #expect(FPSLevel.poor.color == .systemRed)
    }

    // MARK: - FPSCounter initial state

    @Test("Initial FPS is zero")
    func initialFPSIsZero() {
        let counter = FPSCounter()
        #expect(counter.currentFPS == 0)
    }

    @Test("Initial level is poor (0 fps)")
    func initialLevelIsPoor() {
        let counter = FPSCounter()
        #expect(counter.level == .poor)
    }

    // MARK: - Text formatting

    @Test("FPS text formats correctly")
    func fpsTextFormatting() {
        let counter = FPSCounter()
        #expect(counter.fpsText == "0 fps")
    }

    // MARK: - FPSCounterConstants

    @Test("Storage key is correct")
    func storageKeyValue() {
        #expect(FPSCounterConstants.storageKey == "showFPSCounter")
    }

    // MARK: - Start / Stop lifecycle

    @Test("Start and stop do not crash")
    func startStopLifecycle() {
        let counter = FPSCounter()
        counter.start()
        counter.stop()
        #expect(counter.currentFPS == 0)
    }

    @Test("Double start is safe")
    func doubleStartIsSafe() {
        let counter = FPSCounter()
        counter.start()
        counter.start()
        counter.stop()
    }

    @Test("Double stop is safe")
    func doubleStopIsSafe() {
        let counter = FPSCounter()
        counter.start()
        counter.stop()
        counter.stop()
    }

    @Test("Stop without start is safe")
    func stopWithoutStartIsSafe() {
        let counter = FPSCounter()
        counter.stop()
    }

    // MARK: - FPSLevel boundary tests

    @Test("Level at exact boundary 89 is good")
    func levelAt89IsGood() {
        #expect(FPSLevel(fps: 89) == .good)
    }

    @Test("Level at exact boundary 49 is fair")
    func levelAt49IsFair() {
        #expect(FPSLevel(fps: 49) == .fair)
    }

    @Test("Level at very high fps")
    func levelAtVeryHighFPS() {
        #expect(FPSLevel(fps: 240) == .excellent)
    }

    @Test("Level at negative fps defaults to poor")
    func levelAtNegativeFPS() {
        #expect(FPSLevel(fps: -1) == .poor)
    }
}
