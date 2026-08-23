import SwiftUI

/// Building blocks shared by every Settings panel (and the Notch panel):
/// `15/700` section title → 14pt-radius card → rows separated by hairlines.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Design.Font.UI.section)
            content()
        }
        .frame(maxWidth: Design.Layout.cardMaximumWidth, alignment: .leading)
    }
}

/// Card; callers place `Divider()` between rows.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            Design.Color.UI.cardFill,
            in: RoundedRectangle(cornerRadius: Design.Layout.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Design.Layout.cardCornerRadius, style: .continuous)
                .strokeBorder(Design.Color.UI.cardStroke, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.Layout.cardCornerRadius, style: .continuous))
    }
}

/// `Title` on the left, a control on the right. 52pt minimum, `12 16` padding.
struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var minHeight: CGFloat = Design.Layout.settingsRowMinimumHeight
    var titleStyle: HierarchicalShapeStyle = .primary
    var titleFont: Font = Design.Font.UI.body
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(titleStyle)
                if let subtitle {
                    Text(subtitle)
                        .font(Design.Font.UI.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: minHeight)
    }
}

/// `label` left (secondary), `value` right (primary, truncating). 38pt tall.
struct SettingsFactRow: View {
    let label: String
    let value: String
    var isMonospaced = false
    var valueStyle: HierarchicalShapeStyle = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(Design.Font.UI.body)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(value)
                .font(isMonospaced ? Design.Font.UI.mono : Design.Font.UI.body)
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(value)
        }
        .padding(.horizontal, 16)
        .frame(height: Design.Layout.factRowHeight)
    }
}

/// Explanatory line inside a card.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Font.UI.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

/// Buttons placed inside a card row.
struct SettingsButtonRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Scrollable panel body with the standard `24 28 28` insets.
struct SettingsPanelScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .padding(.top, DetailLayout.topInset)
            .padding(.horizontal, DetailLayout.horizontalInset)
            .padding(.bottom, DetailLayout.bottomInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
