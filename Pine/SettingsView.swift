//
//  SettingsView.swift
//  Pine
//

import SwiftUI

/// Native macOS Preferences window with tabbed layout.
/// Added as a `Settings` scene in PineApp — opens via Cmd+,.
struct SettingsView: View {
    @State private var settings = SettingsManager()

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            EditorSettingsTab(settings: settings)
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }
            AppearanceSettingsTab(settings: settings)
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }
        }
        .frame(width: 450, height: 250)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        Form {
            Toggle("Auto-save", isOn: $settings.autoSaveEnabled)
            Toggle("Strip trailing whitespace on save", isOn: $settings.stripTrailingWhitespace)
        }
        .padding()
    }
}

// MARK: - Editor Tab

struct EditorSettingsTab: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        Form {
            HStack {
                Text("Font size:")
                Stepper(
                    value: $settings.fontSize,
                    in: SettingsManager.minFontSize...SettingsManager.maxFontSize,
                    step: 1
                ) {
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                }
            }

            Picker("Tab width:", selection: $settings.tabWidth) {
                Text("2").tag(2)
                Text("4").tag(4)
                Text("8").tag(8)
            }
            .pickerStyle(.segmented)

            Toggle("Show line numbers", isOn: $settings.showLineNumbers)
        }
        .padding()
    }
}

// MARK: - Appearance Tab

struct AppearanceSettingsTab: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        Form {
            Picker("Theme:", selection: $settings.theme) {
                Text("Default").tag("default")
            }

            Toggle("Show minimap", isOn: $settings.showMinimap)
        }
        .padding()
    }
}
