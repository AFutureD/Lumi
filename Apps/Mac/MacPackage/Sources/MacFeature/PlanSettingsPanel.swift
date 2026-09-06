import Transport
import SwiftUI

/// Settings › Plan: one row per sign-in the daemon knows — icon, name, the
/// file it reads, `email · plan` (or the account's problem) and the switch
/// that starts fetching its plan usage.
struct PlanSettingsPanel: View {
    @ObservedObject var model: PlanUsageModel

    var body: some View {
        SettingsPanelScroll {
            SettingsSection(title: "Usage", maxWidth: Design.Layout.settingsWideCardMaximumWidth) {
                SettingsCard {
                    row(.claude, name: "Claude Code", configPath: "Keychain · ~/.claude/.credentials.json")
                    Divider()
                    row(.codex, name: "Codex", configPath: "~/.codex/auth.json")
                    Divider()
                    SettingsFootnote(text: "Lumi reads each agent's own saved sign-in and never refreshes or writes it. Plan usage comes from the provider, refreshed every 5 minutes while the switch is on.")
                }
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
    private func row(_ id: PlanUsageAccountID, name: String, configPath: String) -> some View {
        let account = model.account(id)
        let status = account.flatMap { HaloPlanUsagePresentation.statusText($0) }
        IntegrationRow(
            icon: AgentIcons.image(for: id == .claude ? .claude : .codex, pointSize: 20),
            name: name,
            configPath: configPath,
            subtitle: subtitle(account, status: status),
            isWarning: status != nil && account?.status != .credentialsMissing,
            isInstalled: account?.status == .ok
        ) {
            Toggle(name, isOn: Binding(
                get: { account?.enabled ?? false },
                set: { next in Task { await model.setEnabled(next, for: id) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(model.state == nil || model.updating.contains(id) || account?.status == .credentialsMissing)
            .accessibilityLabel("Fetch \(name) plan usage")
        }
    }

    private func subtitle(_ account: PlanUsageAccount?, status: String?) -> String {
        guard let account else { return model.errorMessage == nil ? "Loading…" : "Daemon not connected" }
        let identity = [account.email, account.plan].compactMap { $0 }.joined(separator: " · ")
        if let status {
            return identity.isEmpty ? status : "\(identity) · \(status)"
        }
        if identity.isEmpty { return account.enabled ? "Signed in" : "Signed in · switched off" }
        return account.enabled ? identity : "\(identity) · switched off"
    }
}
