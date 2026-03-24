//
//  BreadcrumbPathBar.swift
//  Pine
//
//  Horizontal breadcrumb bar showing the active file's path relative to the project root.
//  Each segment is clickable — opens a menu with siblings for quick lateral navigation.
//

import SwiftUI

// TODO: #532 — При рефакторинге ContentView вынести BreadcrumbPathBar в отдельный файл
// (сейчас вставляется напрямую в ContentView).

/// Breadcrumb path bar displayed between the tab bar and the editor.
struct BreadcrumbPathBar: View {
    let fileURL: URL
    let projectRoot: URL
    let onOpenFile: (URL) -> Void

    private var segments: [BreadcrumbSegment] {
        BreadcrumbProvider.segments(for: fileURL, relativeTo: projectRoot)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let allSegments = segments
                let (showEllipsis, visible) = BreadcrumbProvider.truncate(allSegments, maxVisible: 8)

                if showEllipsis {
                    Text("\u{2026}")
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.quaternary)

                    chevronSeparator
                }

                ForEach(Array(visible.enumerated()), id: \.element.id) { index, segment in
                    if index > 0 {
                        chevronSeparator
                    }

                    BreadcrumbSegmentButton(
                        segment: segment,
                        isLast: index == visible.count - 1,
                        projectRoot: projectRoot,
                        onOpenFile: onOpenFile
                    )
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: LayoutMetrics.breadcrumbBarHeight)
        .background(.bar.opacity(0.5))
        .accessibilityIdentifier(AccessibilityID.breadcrumbBar)
    }

    private var chevronSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.quaternary)
    }
}

/// A single clickable breadcrumb segment with a popover for sibling navigation.
private struct BreadcrumbSegmentButton: View {
    let segment: BreadcrumbSegment
    let isLast: Bool
    let projectRoot: URL
    let onOpenFile: (URL) -> Void

    var body: some View {
        Menu {
            let siblings = BreadcrumbProvider.siblings(for: segment, projectRoot: projectRoot)
            ForEach(siblings) { sibling in
                Button {
                    if !sibling.isDirectory {
                        onOpenFile(sibling.url)
                    }
                } label: {
                    Label {
                        Text(sibling.name)
                    } icon: {
                        Image(systemName: sibling.isDirectory
                              ? "folder"
                              : FileIconMapper.iconForFile(sibling.name))
                    }
                }
                .disabled(sibling.isDirectory)
            }
        } label: {
            HStack(spacing: 3) {
                if isLast {
                    Image(systemName: FileIconMapper.iconForFile(segment.name))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(segment.name)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize, weight: isLast ? .medium : .regular))
                    .foregroundStyle(isLast ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.breadcrumbSegment(segment.name))
    }
}
