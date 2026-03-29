//
//  ThemeMenuView.swift
//  Pine
//
//  Submenu for selecting editor color themes.
//

import SwiftUI

/// A menu picker for choosing the editor color theme.
/// Used inside the View menu's CommandGroup.
struct ThemeMenuView: View {
    @State private var themeManager = ThemeManager.shared

    var body: some View {
        Menu {
            Button {
                themeManager.selectTheme(ThemeManager.systemThemeID)
            } label: {
                HStack {
                    Label(Strings.themeSystemDefault, systemImage: MenuIcons.themeSystem)
                    if themeManager.isSystemDefault {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(themeManager.availableThemes) { theme in
                Button {
                    themeManager.selectTheme(theme.id)
                } label: {
                    HStack {
                        Text(theme.name)
                        if themeManager.selectedThemeID == theme.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(Strings.menuEditorTheme, systemImage: MenuIcons.editorTheme)
        }
    }
}
