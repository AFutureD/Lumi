import AgentStatusDesignSystem
import AppKit
import NookApp
import SwiftUI

@MainActor
struct AgentStatusNookSettingsView: View {
    @ObservedObject var appState: AppState
    let showNook: @MainActor () -> Void
    let toggleKeepOpen: @MainActor () -> Void

    @State private var displays = NookScreenLocator.connectedDisplays()

    private static let builtInDisplayTag = "builtIn"
    private static let mainDisplayTag = "main"
    private static let specificDisplayTagPrefix = "uuid:"

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Appearance") {
                SettingsCard {
                    SettingsRow(title: "Surface", minHeight: 52) {
                        Picker("Surface", selection: surfaceBinding) {
                            Text("Solid").tag(NookSurfaceStyle.solid)
                            Text("Translucent").tag(NookSurfaceStyle.translucent)
                            Text("Liquid Glass").tag(NookSurfaceStyle.liquidGlass)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Divider()
                    SettingsRow(title: "Screen", minHeight: 52) {
                        Picker("Screen", selection: displaySelectionBinding) {
                            Text("Built-in Display").tag(Self.builtInDisplayTag)
                            Text("Main Display").tag(Self.mainDisplayTag)
                            if !specificDisplayOptions.isEmpty {
                                Divider()
                                ForEach(specificDisplayOptions, id: \.tag) { option in
                                    Text(option.label).tag(option.tag)
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityLabel("Notch screen")
                    }
                }
            }

            SettingsSection(title: "Adjust") {
                SettingsCard {
                    AgentStatusAdjustmentSliderRow(
                        title: "Compact Width",
                        value: compactWidthBinding,
                        range: AgentStatusNookAdjustmentDefaults.compactWidthRange,
                        step: 1,
                        defaultValue: Double(AgentStatusNookAdjustmentDefaults.compactWidth),
                        valueText: { "\(Int($0.rounded())) pt" }
                    )
                    Divider()
                    AgentStatusAdjustmentSliderRow(
                        title: "Expanded Width",
                        value: expandedWidthBinding,
                        range: AgentStatusNookAdjustmentDefaults.expandedWidthRange,
                        step: 4,
                        defaultValue: Double(AgentStatusNookAdjustmentDefaults.expandedWidth),
                        valueText: { "\(Int($0.rounded())) pt" }
                    )
                    Divider()
                    AgentStatusAdjustmentSliderRow(
                        title: "Expand Animation",
                        value: expandAnimationDurationBinding,
                        range: AgentStatusNookAdjustmentDefaults.expandAnimationDurationRange,
                        step: 0.01,
                        defaultValue: AgentStatusNookAdjustmentDefaults.expandAnimationDuration,
                        valueText: { String(format: "%.2f s", $0) }
                    )
                }
            }

            SettingsSection(title: "Behavior") {
                SettingsCard {
                    SettingsRow(title: "Stay expanded after the pointer leaves") {
                        Toggle("Stay expanded after the pointer leaves", isOn: keepOpenBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider()
                    SettingsRow(title: "Haptic feedback") {
                        Toggle("Haptic feedback", isOn: hapticBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    Divider()
                    SettingsRow(title: "Preview the current settings", minHeight: 52, titleStyle: .secondary) {
                        Button("Show Notch", action: showNook)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            displays = NookScreenLocator.connectedDisplays()
        }
    }

    private var specificDisplayOptions: [(tag: String, label: String)] {
        var options = displays.map { display in
            (
                tag: Self.specificDisplayTagPrefix + display.uuid,
                label: display.isBuiltIn ? "\(display.name) (Built-in)" : display.name
            )
        }
        if appState.displayPreference.mode == .specific,
           let uuid = appState.displayPreference.displayUUID,
           !displays.contains(where: { $0.uuid == uuid }) {
            options.append((
                tag: Self.specificDisplayTagPrefix + uuid,
                label: "Saved Display (Not Connected)"
            ))
        }
        return options
    }

    private var displaySelectionBinding: Binding<String> {
        Binding(
            get: {
                switch appState.displayPreference.mode {
                case .builtIn:
                    Self.builtInDisplayTag
                case .main:
                    Self.mainDisplayTag
                case .specific:
                    Self.specificDisplayTagPrefix + (appState.displayPreference.displayUUID ?? "")
                }
            },
            set: { tag in
                if tag == Self.builtInDisplayTag {
                    appState.replaceDisplayPreference(.builtIn)
                } else if tag == Self.mainDisplayTag {
                    appState.replaceDisplayPreference(.main)
                } else if tag.hasPrefix(Self.specificDisplayTagPrefix) {
                    appState.replaceDisplayPreference(
                        .specific(String(tag.dropFirst(Self.specificDisplayTagPrefix.count)))
                    )
                }
            }
        )
    }

    private var surfaceBinding: Binding<NookSurfaceStyle> {
        preferenceBinding(\.surfaceStyle)
    }

    private var compactWidthBinding: Binding<Double> {
        optionalCGFloatPreferenceBinding(
            \.compactNotchWidth,
            fallback: AgentStatusNookAdjustmentDefaults.compactWidth
        )
    }

    private var expandedWidthBinding: Binding<Double> {
        optionalCGFloatPreferenceBinding(
            \.expandedNotchWidth,
            fallback: AgentStatusNookAdjustmentDefaults.expandedWidth
        )
    }

    private var expandAnimationDurationBinding: Binding<Double> {
        Binding(
            get: {
                appState.appearancePreferences.expandAnimationDuration
                    ?? AgentStatusNookAdjustmentDefaults.expandAnimationDuration
            },
            set: { next in
                var preferences = appState.appearancePreferences
                preferences.expandAnimationDuration = next
                replacePreferences(preferences)
            }
        )
    }

    private var hapticBinding: Binding<Bool> {
        Binding(
            get: { appState.appearancePreferences.hapticFeedbackEnabled },
            set: { next in
                var preferences = appState.appearancePreferences
                preferences.hapticFeedbackEnabled = next
                replacePreferences(preferences)
                NookHaptics.confirm(enabled: next)
            }
        )
    }

    private var keepOpenBinding: Binding<Bool> {
        Binding(
            get: { appState.keepNookOpen },
            set: { next in
                guard next != appState.keepNookOpen else { return }
                toggleKeepOpen()
            }
        )
    }

    private func preferenceBinding<Value>(
        _ keyPath: WritableKeyPath<NookAppearancePreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appState.appearancePreferences[keyPath: keyPath] },
            set: { next in
                var preferences = appState.appearancePreferences
                preferences[keyPath: keyPath] = next
                replacePreferences(preferences)
            }
        )
    }

    private func optionalCGFloatPreferenceBinding(
        _ keyPath: WritableKeyPath<NookAppearancePreferences, CGFloat?>,
        fallback: CGFloat
    ) -> Binding<Double> {
        Binding(
            get: { Double(appState.appearancePreferences[keyPath: keyPath] ?? fallback) },
            set: { next in
                var preferences = appState.appearancePreferences
                preferences[keyPath: keyPath] = CGFloat(next)
                replacePreferences(preferences)
            }
        )
    }

    private func replacePreferences(_ preferences: NookAppearancePreferences) {
        appState.replaceAppearancePreferences(
            AgentStatusNookController.normalizedAppearancePreferences(preferences)
        )
    }
}

private struct AgentStatusAdjustmentSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let valueText: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(AgentStatusDesign.Font.UI.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(AgentStatusDesign.Font.UI.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .opacity(isDefaultValue ? DesignSystem.Opacity.disabledReset : 1)
                .disabled(isDefaultValue)
                .help("Reset \(title)")
                .accessibilityLabel("Reset \(title)")

                Text(valueText(value))
                    .font(AgentStatusDesign.Font.UI.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AgentStatusDesign.Color.UI.chipFill, in: Capsule())
            }

            Slider(value: steppedValue, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText(value))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var steppedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { next in
                let stepped = (next / step).rounded() * step
                value = min(max(stepped, range.lowerBound), range.upperBound)
            }
        )
    }

    private var isDefaultValue: Bool {
        abs(value - defaultValue) < (step / 2)
    }
}
