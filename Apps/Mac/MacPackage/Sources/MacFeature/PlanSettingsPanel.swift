import DesignSystem
import Transport
import SwiftUI

private typealias DS = DesignSystem

/// Settings › Usage › Plan (macOS handoff page 9): one card per sign-in the
/// daemon knows. Header: mark, name, `email · plan`, the read path, the
/// refresh stamp and the switch. Body: one column per reported window
/// (title, `42% used`, a bar of the used share, the reset countdown), or a
/// one-line notice when there is nothing to show yet.
struct PlanSettingsPanel: View {
    @ObservedObject var model: PlanUsageModel

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Plan", maxWidth: DS.PlanUsage.cardMaximumWidth) {
                // Stamps and countdowns move with the clock, not with the snapshot.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 12) {
                        card(.claude, path: "Keychain · ~/.claude/.credentials.json", now: context.date)
                        card(.codex, path: "~/.codex/auth.json", now: context.date)
                    }
                }
                Text("Lumi reads each agent's own saved sign-in and never refreshes or writes it. Plan usage comes from the provider, refreshed every 5 minutes while the switch is on.")
                    .designText(DS.Typography.caption)
                    .foregroundStyle(Design.Color.UI.inkQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                SettingsSection(title: "Daemon") {
                    SettingsCard {
                        SettingsFootnote(text: error)
                    }
                }
            }
        }
        .onAppear { Task { await model.refresh() } }
    }

    @ViewBuilder
    private func card(_ id: PlanUsageAccountID, path: String, now: Date) -> some View {
        let account = model.account(id)
        let provider: AgentProvider = id == .claude ? .claude : .codex
        let status = account.flatMap { HaloPlanUsagePresentation.statusText($0, now: now) }
        let usable = account.map { $0.status != .credentialsMissing } ?? false
        let showsWindows = account.map { $0.enabled && !$0.limits.isEmpty && ($0.status == .ok || $0.status == .rateLimited) } ?? false
        SettingsCard {
            HStack(spacing: DS.PlanUsage.headerGap) {
                if let mark = AgentIcons.image(for: provider.kind, pointSize: DS.PlanUsage.headerMark) {
                    Image(nsImage: mark)
                        .resizable()
                        .frame(width: DS.PlanUsage.headerMark, height: DS.PlanUsage.headerMark)
                        .opacity(usable ? 1 : DS.PlanUsage.unavailableMarkOpacity)
                }
                VStack(alignment: .leading, spacing: DS.PlanUsage.headerLineGap) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.PlanUsage.headerTitleGap) {
                        Text(HaloPlanUsagePresentation.agentName(provider))
                            .designText(DS.Typography.listTitle)
                            .foregroundStyle(Design.Color.UI.inkPrimary)
                        if let identity = identity(account) {
                            Text(identity)
                                .designText(DS.Typography.caption)
                                .foregroundStyle(Design.Color.UI.inkTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(path)
                        .designText(DS.Typography.monoValue)
                        .foregroundStyle(Color(DS.PlanUsage.pathText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let account, account.enabled, let stamp = HaloPlanUsagePresentation.updatedText(account.fetchedAt, now: now) {
                    Text(stamp)
                        .font(SwiftUI.Font(DS.Typography.monoValue).monospacedDigit())
                        .foregroundStyle(Color(DS.PlanUsage.pathText))
                        .fixedSize()
                }
                Toggle(HaloPlanUsagePresentation.agentName(provider), isOn: Binding(
                    get: { account?.enabled ?? false },
                    set: { next in Task { await model.setEnabled(next, for: id) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(account == nil || model.updating.contains(id) || !usable)
                .opacity(usable ? 1 : DS.PlanUsage.disabledSwitchOpacity)
                .accessibilityLabel("Fetch \(HaloPlanUsagePresentation.agentName(provider)) plan usage")
            }
            .padding(.horizontal, DS.PlanUsage.bodyHorizontalPadding)
            .padding(.vertical, DS.PlanUsage.headerVerticalPadding)
            .frame(minHeight: DS.PlanUsage.headerMinimumHeight)

            if showsWindows, let account {
                Divider()
                HStack(alignment: .top, spacing: DS.PlanUsage.columnGap) {
                    ForEach(Array(account.limits.enumerated()), id: \.offset) { _, limit in
                        window(limit, now: now)
                    }
                }
                .padding(.horizontal, DS.PlanUsage.bodyHorizontalPadding)
                .padding(.vertical, DS.PlanUsage.bodyVerticalPadding)
            }
            if let notice = notice(account, status: status, showsWindows: showsWindows, now: now) {
                Divider()
                Text(notice.text)
                    .designText(DS.Typography.planUsageNotice)
                    .foregroundStyle(notice.isWarning ? Design.Color.UI.warningText : Design.Color.UI.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.PlanUsage.bodyHorizontalPadding)
                    .padding(.vertical, DS.PlanUsage.noticeVerticalPadding)
            }
        }
    }

    private func window(_ limit: PlanUsageLimit, now: Date) -> some View {
        let used = limit.usedPercent
        let warning = used >= DS.PlanUsage.warningPercent
        let fill: DesignColor = warning ? DS.PlanUsage.barFillWarning
            : used >= DS.PlanUsage.bandPercent ? DS.PlanUsage.barFillBand
            : DS.PlanUsage.barFill
        return VStack(alignment: .leading, spacing: DS.PlanUsage.columnLineGap) {
            Text(HaloPlanUsagePresentation.windowTitle(limit))
                .designText(DS.Typography.planUsageWindowTitle)
                .foregroundStyle(Design.Color.UI.inkQuaternary)
            HStack(alignment: .firstTextBaseline, spacing: DS.PlanUsage.valueUnitGap) {
                Text("\(Int(used.rounded()))%")
                    .font(SwiftUI.Font(DS.Typography.planUsageValue).monospacedDigit())
                    .foregroundStyle(warning ? Color(DS.PlanUsage.valueWarning) : Design.Color.UI.inkPrimary)
                Text("used")
                    .designText(DS.Typography.caption)
                    .foregroundStyle(Design.Color.UI.inkQuaternary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(DS.PlanUsage.barTrack))
                    Capsule().fill(Color(fill))
                        .frame(width: proxy.size.width * min(max(used, 0), 100) / 100)
                }
            }
            .frame(height: DS.PlanUsage.barHeight)
            if let reset = HaloPlanUsagePresentation.resetText(limit, now: now) {
                Text(reset)
                    .font(SwiftUI.Font(DS.Typography.caption).monospacedDigit())
                    .foregroundStyle(Design.Color.UI.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func identity(_ account: PlanUsageAccount?) -> String? {
        guard let account else { return nil }
        let parts = [account.email, account.plan].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func notice(_ account: PlanUsageAccount?, status: String?, showsWindows: Bool, now: Date) -> (text: String, isWarning: Bool)? {
        guard let account else {
            return (model.errorMessage == nil ? "Loading…" : "Daemon not connected.", false)
        }
        let agent = HaloPlanUsagePresentation.agentName(account.provider)
        switch account.status {
        case .credentialsMissing:
            return ("\(status ?? "Not signed in"). Once you sign in with \(agent), this card becomes available on its own.", true)
        case .signInExpired, .signInRejected, .failed:
            return ("\(status ?? "Unavailable"). Plan limits resume after the next successful sign-in.", true)
        case .rateLimited:
            let stamp = HaloPlanUsagePresentation.updatedText(account.fetchedAt, now: now)
            return ("\(status ?? "Rate limited"). " + (stamp.map { "The numbers above are from the last answer, \($0)." } ?? "No answer has arrived yet."), true)
        case .ok:
            if !account.enabled {
                return ("Switched off: Lumi is not asking the provider for this Mac's plan limits. Turn it on to fetch now and every 5 minutes after.", false)
            }
            if !showsWindows { return ("Fetching from the provider…", false) }
            return nil
        }
    }
}
