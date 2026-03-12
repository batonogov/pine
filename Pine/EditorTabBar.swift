//
//  EditorTabBar.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import SwiftUI

/// Internal tab bar for editor tabs, styled like the terminal tab bar.
struct EditorTabBar: View {
    var tabManager: TabManager

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabManager.tabs) { tab in
                        EditorTabItem(
                            tab: tab,
                            isActive: tab.id == tabManager.activeTabID,
                            onSelect: { tabManager.activeTabID = tab.id },
                            onClose: { tabManager.closeTab(id: tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()
        }
        .frame(height: 30)
        .background(.bar)
    }
}

/// A single editor tab item (capsule style, matching terminal tabs).
struct EditorTabItem: View {
    let tab: EditorTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Close button — visible on hover or when active
            Button(action: onClose) {
                ZStack {
                    if tab.isDirty && !isHovering {
                        // Dirty dot when not hovering
                        Circle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
                .background(
                    isHovering ? Color.primary.opacity(0.1) : .clear,
                    in: Circle()
                )
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isActive || tab.isDirty ? 1 : 0)

            Image(systemName: FileIconMapper.iconForFile(tab.fileName))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(tab.fileName)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
