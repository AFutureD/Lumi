import SwiftUI

/// The glass metric card: a large monospaced-digit value over a small
/// uppercase label. The session Inspector's Tokens / Context / Elapsed.
struct MetricCardView<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            value()
                .font(Design.Font.UI.metricValue)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(Design.Font.UI.metricLabel)
                .kerning(0.4)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 5, y: 4)
    }
}
