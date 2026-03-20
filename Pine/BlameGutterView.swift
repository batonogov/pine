//
//  BlameGutterView.swift
//  Pine
//

import AppKit

/// NSView that displays git blame annotations in the editor gutter.
/// Positioned to the left of LineNumberView.
final class BlameGutterView: NSView {
    weak var textView: NSTextView?

    static let defaultWidth: CGFloat = 200

    var blameLines: [GitBlameLine] = [] {
        didSet { needsDisplay = true }
    }

    private let textColor = NSColor.secondaryLabelColor
    private let bgColor = NSColor.controlBackgroundColor
    private let separatorColor = NSColor.separatorColor
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        frame.size.width = Self.defaultWidth

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBoundsChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        textView?.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleBoundsChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView == textView?.enclosingScrollView?.contentView else { return }
        needsDisplay = true
    }

    @objc private func contentDidChange() {
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView
        else { return }

        bgColor.setFill()
        bounds.fill()

        // Separator line at right edge
        separatorColor.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: bounds.width - 0.5, y: 0))
        sep.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.height))
        sep.lineWidth = 1
        sep.stroke()

        guard !blameLines.isEmpty else { return }

        // Build lookup: finalLine → index in blameLines
        let blameLookup = Dictionary(
            blameLines.enumerated().map { ($1.finalLine, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Compute heat map alpha values
        let alphaMap = computeHeatMap()

        let visibleRect = scrollView.contentView.bounds
        let originY = textView.textContainerOrigin.y
        let source = textView.string as NSString

        guard source.length > 0 else { return }

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        guard visibleGlyphRange.location != NSNotFound else { return }

        let firstVisibleCharIndex = layoutManager.characterIndexForGlyph(
            at: visibleGlyphRange.location
        )
        var lineNumber = 1
        if firstVisibleCharIndex > 0 {
            for i in 0..<firstVisibleCharIndex where source.character(at: i) == 0x0A {
                lineNumber += 1
            }
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]

        var previousLineCharIndex = -1
        var lastDrawnHash: String?
        let groupSepColor = NSColor.separatorColor.withAlphaComponent(0.5)

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { lineRect, _, _, glyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)

            let isNewLogicalLine: Bool
            if previousLineCharIndex < 0 {
                isNewLogicalLine = true
            } else if charIndex > previousLineCharIndex {
                let range = NSRange(location: previousLineCharIndex,
                                    length: charIndex - previousLineCharIndex)
                isNewLogicalLine = source.substring(with: range).contains("\n")
            } else {
                isNewLogicalLine = false
            }

            if isNewLogicalLine {
                let y = lineRect.origin.y + originY - visibleRect.origin.y

                if let blameIndex = blameLookup[lineNumber] {
                    let blame = self.blameLines[blameIndex]

                    // Group separator between different commits
                    if let lastHash = lastDrawnHash, lastHash != blame.hash {
                        groupSepColor.setStroke()
                        let sepPath = NSBezierPath()
                        sepPath.move(to: NSPoint(x: 4, y: y))
                        sepPath.line(to: NSPoint(x: self.bounds.width - 4, y: y))
                        sepPath.lineWidth = 0.5
                        sepPath.stroke()
                    }

                    // Only draw info for first line of each group
                    let isFirstInGroup = blameIndex == 0
                        || self.blameLines[blameIndex - 1].hash != blame.hash
                    let isFirstVisible = lastDrawnHash != blame.hash

                    if isFirstInGroup || isFirstVisible {
                        let alpha = alphaMap[blame.hash] ?? 0.6
                        let blameText = self.formatBlameLine(blame)
                        var lineAttrs = attrs
                        lineAttrs[.foregroundColor] = self.textColor.withAlphaComponent(alpha)
                        let attrStr = NSAttributedString(string: blameText, attributes: lineAttrs)
                        attrStr.draw(at: NSPoint(x: 4, y: y))
                    }

                    lastDrawnHash = blame.hash
                }

                lineNumber += 1
            }

            previousLineCharIndex = charIndex
        }
    }

    // MARK: - Heat map

    private func computeHeatMap() -> [String: CGFloat] {
        guard !blameLines.isEmpty else { return [:] }

        // Collect unique commit times
        var commitTimes: [String: TimeInterval] = [:]
        for line in blameLines {
            commitTimes[line.hash] = line.authorTime.timeIntervalSince1970
        }

        guard let minTime = commitTimes.values.min(),
              let maxTime = commitTimes.values.max() else { return [:] }

        let range = maxTime - minTime
        guard range > 0 else {
            // All same time — uniform alpha
            return commitTimes.mapValues { _ in CGFloat(0.7) }
        }

        // Normalize: older → 0.35, newer → 1.0
        return commitTimes.mapValues { time in
            let normalized = (time - minTime) / range
            return CGFloat(0.35 + normalized * 0.65)
        }
    }

    // MARK: - Formatting

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    private func formatBlameLine(_ blame: GitBlameLine) -> String {
        if blame.isUncommitted {
            return "Uncommitted"
        }
        let shortHash = String(blame.hash.prefix(7))
        let date = Self.dateFormatter.string(from: blame.authorTime)
        // Truncate author to fit
        let maxAuthorLen = 12
        let authorName = blame.author.count > maxAuthorLen
            ? String(blame.author.prefix(maxAuthorLen - 1)) + "…"
            : blame.author
        return "\(shortHash) \(authorName) \(date)"
    }

    // MARK: - Click handling

    override func mouseDown(with event: NSEvent) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        let locationInView = convert(event.locationInWindow, from: nil)
        let visibleRect = scrollView.contentView.bounds
        let originY = textView.textContainerOrigin.y
        let source = textView.string as NSString

        guard source.length > 0 else { return }

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        guard visibleGlyphRange.location != NSNotFound else { return }

        let firstVisibleCharIndex = layoutManager.characterIndexForGlyph(
            at: visibleGlyphRange.location
        )
        var lineNumber = 1
        if firstVisibleCharIndex > 0 {
            for i in 0..<firstVisibleCharIndex where source.character(at: i) == 0x0A {
                lineNumber += 1
            }
        }

        var previousLineCharIndex = -1
        var clickedLine: Int?

        layoutManager.enumerateLineFragments(
            forGlyphRange: visibleGlyphRange
        ) { lineRect, _, _, glyphRange, stop in
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)

            let isNewLogicalLine: Bool
            if previousLineCharIndex < 0 {
                isNewLogicalLine = true
            } else if charIndex > previousLineCharIndex {
                let range = NSRange(location: previousLineCharIndex,
                                    length: charIndex - previousLineCharIndex)
                isNewLogicalLine = source.substring(with: range).contains("\n")
            } else {
                isNewLogicalLine = false
            }

            if isNewLogicalLine {
                let y = lineRect.origin.y + originY - visibleRect.origin.y
                if locationInView.y >= y && locationInView.y < y + lineRect.height {
                    clickedLine = lineNumber
                    stop.pointee = true
                }
                lineNumber += 1
            }

            previousLineCharIndex = charIndex
        }

        guard let line = clickedLine,
              let blame = blameLines.first(where: { $0.finalLine == line }),
              !blame.isUncommitted else { return }

        NotificationCenter.default.post(
            name: .blameLineClicked,
            object: nil,
            userInfo: ["blameLine": blame]
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    static let blameLineClicked = Notification.Name("blameLineClicked")
}
