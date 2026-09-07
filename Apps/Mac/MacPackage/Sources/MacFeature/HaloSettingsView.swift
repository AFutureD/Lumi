import DesignSystem
import Transport
import AppKit
import NookApp
import SwiftUI

@MainActor
struct HaloSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var planUsage: PlanUsageModel
    @ObservedObject var planUsagePreferences: HaloPlanUsagePreferences
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
                    AdjustmentSliderRow(
                        title: "Compact Width",
                        value: compactWidthBinding,
                        range: HaloAdjustmentDefaults.compactWidthRange,
                        step: 1,
                        defaultValue: Double(HaloAdjustmentDefaults.compactWidth),
                        valueText: { "\(Int($0.rounded())) pt" }
                    )
                    Divider()
                    AdjustmentSliderRow(
                        title: "Expanded Width",
                        value: expandedWidthBinding,
                        range: HaloAdjustmentDefaults.expandedWidthRange,
                        step: 4,
                        defaultValue: Double(HaloAdjustmentDefaults.expandedWidth),
                        valueText: { "\(Int($0.rounded())) pt" }
                    )
                    Divider()
                    AdjustmentSliderRow(
                        title: "Expand Animation",
                        value: expandAnimationDurationBinding,
                        range: HaloAdjustmentDefaults.expandAnimationDurationRange,
                        step: 0.01,
                        defaultValue: HaloAdjustmentDefaults.expandAnimationDuration,
                        valueText: { String(format: "%.2f s", $0) }
                    )
                }
            }

            // Plan usage in the top bar (macOS handoff page 7b): preview
            // first, the two single-choice rows, then the multi-select pills.
            SettingsSection(title: "Usage") {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Preview")
                                .font(Design.Font.UI.body)
                            Spacer(minLength: 8)
                            Text(planUsagePreferences.agentsMode == .showBoth
                                 ? "Both agents side by side, 8pt apart."
                                 : "Click the preview to switch to the other agent.")
                                .font(Design.Font.UI.caption)
                                .foregroundStyle(Design.Color.UI.inkQuaternary)
                        }
                        HaloPlanUsagePreviewStrip(model: planUsage, preferences: planUsagePreferences)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Divider()
                    SettingsRow(title: "Agents", minHeight: 52) {
                        Picker("Agents", selection: $planUsagePreferences.agentsMode) {
                            Text("Switch on click").tag(PlanUsageAgentsMode.switchOnClick)
                            Text("Show both").tag(PlanUsageAgentsMode.showBoth)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Divider()
                    SettingsRow(title: "Percent", minHeight: 52) {
                        Picker("Percent", selection: $planUsagePreferences.percentStyle) {
                            Text("Used").tag(PlanUsagePercentStyle.used)
                            Text("Remaining").tag(PlanUsagePercentStyle.remaining)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show")
                            .font(Design.Font.UI.body)
                        Text("Pick any number of windows · none picked hides plan usage")
                            .font(Design.Font.UI.caption)
                            .foregroundStyle(Design.Color.UI.inkQuaternary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    Divider()
                    HaloPlanUsageShowRow(provider: .claude, model: planUsage, preferences: planUsagePreferences)
                    Divider()
                    HaloPlanUsageShowRow(provider: .codex, model: planUsage, preferences: planUsagePreferences)
                    Divider()
                    SettingsFootnote(text: "Windows the provider does not report have no pill and take no room in the top bar; an agent with nothing picked has no group there. Order is fixed: 5-hour → Weekly → Fable.")
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
            fallback: HaloAdjustmentDefaults.compactWidth
        )
    }

    private var expandedWidthBinding: Binding<Double> {
        optionalCGFloatPreferenceBinding(
            \.expandedNotchWidth,
            fallback: HaloAdjustmentDefaults.expandedWidth
        )
    }

    private var expandAnimationDurationBinding: Binding<Double> {
        Binding(
            get: {
                appState.appearancePreferences.expandAnimationDuration
                    ?? HaloAdjustmentDefaults.expandAnimationDuration
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
            HaloController.normalizedAppearancePreferences(preferences)
        )
    }
}

private struct AdjustmentSliderRow: View {
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
                    .font(Design.Font.UI.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(Design.Font.UI.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .opacity(isDefaultValue ? DesignSystem.Opacity.disabledReset : 1)
                .disabled(isDefaultValue)
                .help("Reset \(title)")
                .accessibilityLabel("Reset \(title)")

                Text(valueText(value))
                    .font(Design.Font.UI.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Design.Color.UI.chipFill, in: Capsule())
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

/// One agent under Settings › Notch › Usage › Show: mark, name (with the
/// reason when there is nothing to pick), then one multi-select pill per
/// window the provider reports, left-aligned after the name.
private struct HaloPlanUsageShowRow: View {
    let provider: AgentProvider
    @ObservedObject var model: PlanUsageModel
    @ObservedObject var preferences: HaloPlanUsagePreferences

    private typealias PU = DesignSystem.PlanUsage

    var body: some View {
        let account = model.state?.accounts.first { $0.provider == provider }
        let items = account.map(HaloPlanUsagePresentation.availableItems) ?? []
        let reason = items.isEmpty ? HaloPlanUsagePresentation.unavailableReason(account) : nil
        HStack(spacing: PU.showRowGap) {
            if let mark = AgentIcons.image(for: provider.kind, pointSize: PU.showMark) {
                Image(nsImage: mark)
                    .resizable()
                    .frame(width: PU.showMark, height: PU.showMark)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(HaloPlanUsagePresentation.agentName(provider))
                    .font(Design.Font.UI.body)
                if let reason {
                    Text(reason)
                        .designText(DesignSystem.Typography.footnote)
                        .foregroundStyle(Design.Color.UI.warningText)
                        .lineLimit(2)
                }
            }
            .frame(width: PU.showNameWidth, alignment: .leading)
            HStack(spacing: PU.pillGap) {
                ForEach(items, id: \.self) { item in
                    pill(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, PU.showRowVerticalPadding)
        .frame(minHeight: PU.showRowMinimumHeight)
        .opacity(items.isEmpty ? PU.unavailableRowOpacity : 1)
    }

    private func pill(_ item: PlanUsageItem) -> some View {
        let selected = preferences.items.contains(item)
        return Button {
            preferences.toggle(item)
        } label: {
            HStack(spacing: PU.pillInnerGap) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: PU.pillCheck, weight: .semibold))
                }
                Text(item.pillTitle)
                    .designText(DesignSystem.Typography.planUsagePill)
            }
            .foregroundStyle(Color(selected ? PU.pillSelectedText : PU.pillText))
            .padding(.horizontal, PU.pillHorizontalPadding)
            .frame(height: PU.pillHeight)
            .background(Color(selected ? PU.pillSelectedFill : PU.pillFill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(selected ? PU.pillSelectedRing : PU.pillRing), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(HaloPlanUsagePresentation.agentName(provider)) \(item.pillTitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
