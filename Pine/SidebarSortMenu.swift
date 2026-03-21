//
//  SidebarSortMenu.swift
//  Pine
//

import SwiftUI

/// A "Sort By" submenu shown in the sidebar's background context menu.
/// Provides Finder-like sort options with a checkmark on the active mode
/// and an ascending/descending toggle.
struct SidebarSortMenu: View {
    @Bindable var workspace: WorkspaceManager

    var body: some View {
        Menu {
            Picker(selection: $workspace.sortOrder) {
                Label(Strings.sortByName, systemImage: "character")
                    .tag(FileSortOrder.name)
                Label(Strings.sortByDateModified, systemImage: "calendar")
                    .tag(FileSortOrder.dateModified)
                Label(Strings.sortBySize, systemImage: "doc.badge.arrow.up")
                    .tag(FileSortOrder.size)
                Label(Strings.sortByType, systemImage: "doc.text")
                    .tag(FileSortOrder.type)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            Picker(selection: $workspace.sortDirection) {
                Label(Strings.sortAscending, systemImage: MenuIcons.sortAscending)
                    .tag(FileSortDirection.ascending)
                Label(Strings.sortDescending, systemImage: MenuIcons.sortDescending)
                    .tag(FileSortDirection.descending)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Label(Strings.sortBy, systemImage: MenuIcons.sortBy)
        }
    }
}
