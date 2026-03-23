//
//  FPSCounter.swift
//  Pine
//
//  Created by Claude on 23.03.2026.
//

import AppKit
import QuartzCore

/// Performance level based on measured frame rate.
enum FPSLevel {
    case excellent // ≥ 90 fps (ProMotion territory)
    case good      // ≥ 50 fps
    case fair      // ≥ 30 fps
    case poor      // < 30 fps

    init(fps: Int) {
        switch fps {
        case 90...: self = .excellent
        case 50...: self = .good
        case 30...: self = .fair
        default:    self = .poor
        }
    }

    var color: NSColor {
        switch self {
        case .excellent: .systemGreen
        case .good:      .systemYellow
        case .fair:      .systemOrange
        case .poor:      .systemRed
        }
    }
}

/// UserDefaults key for FPS counter visibility.
enum FPSCounterConstants {
    static let storageKey = "showFPSCounter"
}

/// Monitors frame rate using CADisplayLink via NSScreen.
///
/// Shows real-time FPS to help diagnose scroll performance on ProMotion displays.
/// Available in DEBUG builds via View menu, or in any build via:
/// `defaults write com.batonogov.pine-editor showFPSCounter -bool YES`
@Observable
final class FPSCounter: NSObject {
    private(set) var currentFPS: Int = 0

    var level: FPSLevel { FPSLevel(fps: currentFPS) }

    /// Formatted FPS string (e.g. "120 fps").
    var fpsText: String { "\(currentFPS) fps" }

    // MARK: - CADisplayLink

    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var lastSampleTime: CFTimeInterval = 0

    /// How often to update the displayed FPS value (in seconds).
    private let sampleInterval: CFTimeInterval = 0.5

    func start() {
        guard displayLink == nil else { return }

        frameCount = 0
        lastSampleTime = CACurrentMediaTime()

        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(handleFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        currentFPS = 0
    }

    @objc private func handleFrame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        frameCount += 1

        let elapsed = now - lastSampleTime
        if elapsed >= sampleInterval {
            currentFPS = Int(round(Double(frameCount) / elapsed))
            frameCount = 0
            lastSampleTime = now
        }
    }

    deinit {
        stop()
    }
}
