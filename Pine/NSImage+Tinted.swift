//
//  NSImage+Tinted.swift
//  Pine
//
//  Extracted from CodeEditorView.swift on 2026-04-09 (issue #755).
//

import AppKit

// MARK: - NSImage tinting

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }
}
