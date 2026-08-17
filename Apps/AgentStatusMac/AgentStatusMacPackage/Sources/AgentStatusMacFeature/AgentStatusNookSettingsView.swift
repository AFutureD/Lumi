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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("Appearance") {
                    AgentStatusSettingsCard {
                        surfaceRow
                        Divider()
                        displayRow
                    }
                }

                settingsSection("Adjust") {
                    AgentStatusSettingsCard {
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

                settingsSection("Behavior") {
                    AgentStatusSettingsCard {
                        Toggle("Stay expanded after the pointer leaves", isOn: keepOpenBinding)
                        Divider()
                        Toggle("Haptic feedback", isOn: hapticBinding)
                        Divider()
                        HStack {
                            Text("Preview the current settings")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Show Notch", action: showNook)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .frame(
                minWidth: AgentStatusDetailLayout.minimumContentWidth,
                maxWidth: AgentStatusDetailLayout.maximumContentWidth,
                alignment: .topLeading
            )
            .padding(.horizontal, AgentStatusDetailLayout.horizontalInset)
            .padding(.bottom, AgentStatusDetailLayout.bottomInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            displays = NookScreenLocator.connectedDisplays()
        }
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            content()
        }
    }

    private var surfaceRow: some View {
        HStack(spacing: 16) {
            Text("Surface")
                .fixedSize()
            Spacer()
            Picker("Surface", selection: surfaceBinding) {
                Text("Solid").tag(NookSurfaceStyle.solid)
                Text("Translucent").tag(NookSurfaceStyle.translucent)
                Text("Liquid Glass").tag(NookSurfaceStyle.liquidGlass)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 270)
        }
    }

    private var displayRow: some View {
        HStack(spacing: 16) {
            Text("Screen")
            Spacer()
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
            .frame(width: 220, alignment: .trailing)
            .accessibilityLabel("Notch screen")
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

private struct AgentStatusSettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
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
            HStack {
                Text(title)
                Spacer()
                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(isDefaultValue)
                .help("Reset \(title)")
                .accessibilityLabel("Reset \(title)")

                Text(valueText(value))
                    .font(.system(.body, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            Slider(value: steppedValue, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText(value))
        }
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
