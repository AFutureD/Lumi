import Core
import DesignSystem
import Transport
import AppKit
import SwiftUI

/// The Usage page body: a Summary card (Cost and Tokens with their
/// captions, the token composition bar, Sessions / Turns / Calls, the trend
/// chart) over a Detail card (one table, grouped by Project / Agent / Time /
/// Model). Everything shown comes from the model's reports; the view holds
/// only hover, sort and layout state.
struct UsageReportView: View {
    typealias DS = DesignSystem

    @ObservedObject var model: UsageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Usage.cardGap) {
                content
            }
            .frame(maxWidth: DS.Usage.contentMaximumWidth, alignment: .topLeading)
            .padding(.top, DS.Spacing.xl + DS.Spacing.xs)
            .padding(.horizontal, DetailLayout.horizontalInset)
            .padding(.bottom, DetailLayout.bottomInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorMessage {
            UsageNotice(text: error, isError: true)
        }
        if let report = model.report {
            let scanning = report.scan.isScanning || report.scan.pendingFiles > 0
            if scanning {
                UsageNotice(
                    text: report.scan.pendingFiles > 0
                        ? "Scanning transcripts · \(UsageFormatting.count(report.scan.pendingFiles)) files left"
                        : "Scanning transcripts…",
                    isError: false
                )
            }
            let hasUsage = report.totals.calls > 0 || report.totals.tokens.total > 0
            if hasUsage || !scanning {
                UsageSummaryCard(
                    model: model,
                    report: report,
                    emptyText: hasUsage ? nil : (report.scan.scannedFiles == 0 ? "No usage yet" : "No usage in this range")
                )
            }
            if hasUsage {
                UsageDetailCard(model: model, report: report)
            }
        } else if model.isLoading {
            HStack(spacing: DS.Spacing.m) {
                ProgressView().controlSize(.small)
                Text("Loading usage…")
                    .font(Font(DS.Typography.body))
                    .foregroundStyle(Color(DS.Usage.secondaryText))
            }
        }
    }
}

// MARK: - Cards

/// A 14pt-radius white card with a 36pt header: title on the left, controls
/// on the right, a hairline under it.
private struct UsageCard<Header: View, Content: View>: View {
    typealias DS = DesignSystem

    let title: String
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Usage.groupControlGap) {
                Text(title)
                    .font(Font(DS.Typography.bodyEmphasized))
                    .foregroundStyle(Color(DS.Usage.primaryText))
                header()
            }
            .padding(.horizontal, DS.Usage.cardInset)
            .frame(height: DS.Usage.cardHeaderHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(DS.Usage.rowSeparator)).frame(height: DS.Stroke.separator)
            }
            content()
        }
        .background(Color(DS.Usage.cardFill), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(Color(DS.Usage.cardRing), lineWidth: DS.Stroke.hairline)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(color: Color(DS.Usage.cardShadow), radius: DS.Usage.cardShadowBlur / 2, y: DS.Usage.cardShadowOffsetY)
    }
}

private struct UsageSummaryCard: View {
    typealias DS = DesignSystem

    @ObservedObject var model: UsageModel
    let report: UsageReport
    /// Replaces the trend chart when the range holds no usage.
    let emptyText: String?

    private var figures: UsageSummaryFigures {
        UsageSummaryFigures.build(report: report, agent: model.summaryAgent, comparisonLabel: model.comparisonLabel)
    }

    private var trend: UsageTrend {
        UsageTrend.build(report: report, range: model.range, agent: model.summaryAgent, calendar: model.calendar)
    }

    /// Cost has nothing to draw when every model is unpriced: the chart
    /// falls back to Tokens.
    private func metric(_ figures: UsageSummaryFigures) -> UsageTrendMetric {
        figures.allUnpriced ? .tokens : model.trendMetric
    }

    var body: some View {
        UsageCard(title: "Summary") {
            Spacer(minLength: 0)
            UsageSegmentedPicker("Agent", selection: $model.summaryAgent)
        } content: {
            let figures = figures
            HStack(alignment: .top, spacing: DS.Usage.columnGap) {
                metrics(figures)
                    .frame(width: DS.Usage.metricsColumnWidth)
                if let emptyText {
                    Text(emptyText)
                        .font(Font(DS.Typography.body))
                        .foregroundStyle(Color(DS.Usage.tertiaryText))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    trendColumn(figures)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.top, DS.Usage.bodyTop)
            .padding(.horizontal, DS.Usage.cardInset)
            .padding(.bottom, DS.Usage.bodyBottom)
        }
    }

    private func metrics(_ figures: UsageSummaryFigures) -> some View {
        VStack(alignment: .leading, spacing: DS.Usage.metricsBlockGap) {
            VStack(alignment: .leading, spacing: DS.Usage.labelGap) {
                UsageSmallLabel(text: "Cost")
                UsageBigNumber(text: figures.cost, help: figures.allUnpriced ? "No published price for any model in this range" : nil)
                UsageCaption(text: figures.costDelta)
            }
            separator
            VStack(alignment: .leading, spacing: DS.Usage.labelGap) {
                UsageSmallLabel(text: "Tokens")
                UsageBigNumber(text: figures.tokens, help: figures.tokensExact)
                UsageCompositionBar(segments: figures.segments)
                    .padding(.top, DS.Usage.compositionBarTopGap - DS.Usage.labelGap)
                UsageCaption(text: figures.composition)
            }
            separator
            HStack(alignment: .top, spacing: DS.Usage.figureGap) {
                figure("Sessions", figures.sessions)
                figure("Turns", figures.turns)
                figure("Calls", figures.calls)
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Color(DS.Usage.tableHeaderSeparator)).frame(height: DS.Stroke.separator)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Usage.labelGap) {
            UsageSmallLabel(text: label)
            Text(value)
                .font(Font(DS.Typography.usageFigure).monospacedDigit())
                .foregroundStyle(Color(DS.Usage.primaryText))
        }
    }

    private func trendColumn(_ figures: UsageSummaryFigures) -> some View {
        let trend = trend
        let metric = metric(figures)
        return VStack(alignment: .leading, spacing: DS.Chart.blockGap) {
            HStack {
                Text(trend.title(metric))
                    .designText(DS.Typography.usageLabel)
                    .foregroundStyle(Color(DS.Usage.secondaryText))
                Spacer(minLength: 0)
                UsageSegmentedPicker("Metric", selection: $model.trendMetric)
                    .disabled(figures.allUnpriced)
            }
            .frame(height: DS.Chart.titleHeight)
            UsageTrendChart(trend: trend, metric: metric)
        }
    }
}

private struct UsageDetailCard: View {
    typealias DS = DesignSystem

    @ObservedObject var model: UsageModel
    let report: UsageReport

    private var rows: UsageDetailRows {
        UsageDetailRows.build(report: report, group: model.detailGroup, timeUnit: model.detailTimeUnit, calendar: model.calendar)
    }

    /// Sort state lives in the table; a new grouping or range starts it over.
    private var tableIdentity: String {
        "\(model.detailGroup.rawValue)/\(model.detailTimeUnit.rawValue)/\(report.since.rawValue)/\(report.until.rawValue)"
    }

    var body: some View {
        UsageCard(title: "Detail") {
            HStack(spacing: DS.Usage.groupLabelGap) {
                UsageHint(text: "Group by")
                UsageSegmentedPicker("Group by", selection: $model.detailGroup)
                if model.detailGroup == .time {
                    UsageSegmentedPicker("Time unit", selection: $model.detailTimeUnit)
                }
            }
            Spacer(minLength: 0)
            if model.summaryAgent != .all {
                UsageHint(text: "Not filtered by the Summary agent")
            }
        } content: {
            let rows = rows
            UsageTable(columns: rows.columns, rows: rows.rows, collapsed: $model.collapsedGroups)
                .id(tableIdentity)
            if let footnote = rows.footnote {
                UsageHint(text: footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Usage.rowInset)
                    .padding(.vertical, DS.Usage.footnoteVerticalPadding)
            }
        }
    }
}

// MARK: - Pieces

/// The system segmented control at the page's small size, one segment per case.
private struct UsageSegmentedPicker<Value: CaseIterable & Hashable & UsageTitled>: View where Value.AllCases: RandomAccessCollection {
    let title: String
    @Binding var selection: Value

    init(_ title: String, selection: Binding<Value>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Value.allCases), id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }
}

/// Small tertiary text: control labels, the Detail note, the footnote.
private struct UsageHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font(DesignSystem.Typography.subheadline))
            .foregroundStyle(Color(DesignSystem.Usage.tertiaryText))
    }
}

private struct UsageSmallLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .designText(DesignSystem.Typography.usageLabel)
            .foregroundStyle(Color(DesignSystem.Usage.tertiaryText))
    }
}

private struct UsageBigNumber: View {
    let text: String
    var help: String?

    var body: some View {
        Text(text)
            .designText(DesignSystem.Typography.usageMetricValue)
            .monospacedDigit()
            .foregroundStyle(Color(DesignSystem.Usage.primaryText))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .help(help ?? text)
    }
}

private struct UsageCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font(DesignSystem.Typography.subheadline))
            .foregroundStyle(Color(DesignSystem.Usage.secondaryText))
            .lineLimit(1)
    }
}

/// The token composition bar: Input → Cache read → Cache write → Output,
/// summing to the full width; segments under half a pixel simply vanish.
private struct UsageCompositionBar: View {
    typealias DS = DesignSystem

    let segments: [UsageSummaryFigures.Segment]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(Color(segment.color))
                        .frame(width: geometry.size.width * segment.fraction)
                }
            }
        }
        .frame(height: DS.Usage.compositionBarHeight)
        .background(Color(DS.Usage.compositionTrack))
        .clipShape(RoundedRectangle(cornerRadius: DS.Usage.compositionBarRadius, style: .continuous))
    }
}

/// Scanning notice (grey) or IPC error (red) above the cards.
private struct UsageNotice: View {
    typealias DS = DesignSystem

    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: DS.Usage.noticeGap) {
            Image(systemName: isError ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .font(.system(size: DS.Usage.noticeIcon - 2, weight: .medium))
                .frame(width: DS.Usage.noticeIcon, height: DS.Usage.noticeIcon)
            Text(text)
                .font(Font(DS.Typography.body))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(isError ? DS.Usage.errorText : DS.Usage.noticeText))
        .padding(.vertical, DS.Usage.noticeVerticalPadding)
        .padding(.horizontal, DS.Usage.noticeHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(isError ? DS.Usage.errorFill : DS.Usage.noticeFill), in: RoundedRectangle(cornerRadius: DS.Usage.noticeRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Usage.noticeRadius, style: .continuous)
                .strokeBorder(Color(isError ? DS.Usage.errorRing : DS.Usage.noticeRing), lineWidth: DS.Stroke.hairline)
        }
    }
}
