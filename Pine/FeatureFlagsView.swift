//
//  FeatureFlagsView.swift
//  Pine
//
//  Settings view for toggling feature flags at runtime.
//

import SwiftUI

struct FeatureFlagsView: View {
    private let featureFlags = FeatureFlags.shared

    var body: some View {
        Form {
            Section {
                ForEach(Feature.allCases) { feature in
                    Toggle(isOn: binding(for: feature)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.displayName)
                            Text(feature.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.featureFlagToggle(feature.rawValue))
                }
            } header: {
                Text(Strings.featureFlagsHeader)
            } footer: {
                Text(Strings.featureFlagsFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(Strings.featureFlagsResetAll) {
                    featureFlags.resetAll()
                }
                .accessibilityIdentifier(AccessibilityID.featureFlagsResetButton)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 300)
    }

    private func binding(for feature: Feature) -> Binding<Bool> {
        Binding(
            get: { featureFlags.isEnabled(feature) },
            set: { featureFlags.setEnabled(feature, $0) }
        )
    }
}
