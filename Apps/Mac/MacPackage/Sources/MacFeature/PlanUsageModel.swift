import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Mac's copy of the daemon's plan-usage snapshot, shared by Settings ›
/// Plan (the switches), Settings › Notch › Usage (the display choices and
/// their preview) and the Notch top bar. Polled every minute for as long as
/// the app runs — the Notch is always on screen — and at once when the
/// daemon comes back.
@MainActor
final class PlanUsageModel: ObservableObject {
    @Published private(set) var state: PlanUsageState?
    /// The last failure, cleared by the next successful load.
    @Published private(set) var errorMessage: String?
    /// Accounts with a switch in flight; their toggles are disabled meanwhile.
    @Published private(set) var updating: Set<PlanUsageAccountID> = []
    /// How the Notch shows the numbers — the Mac's own choices.
    let preferences: HaloPlanUsagePreferences

    private let client: PlanUsageClient
    private weak var store: MacSessionStore?
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var daemonWasAvailable = false

    init(
        client: PlanUsageClient = PlanUsageClient(),
        store: MacSessionStore? = nil,
        pollInterval: Duration = .seconds(60),
        preferences: HaloPlanUsagePreferences = HaloPlanUsagePreferences()
    ) {
        self.client = client
        self.store = store
        self.pollInterval = pollInterval
        self.preferences = preferences
        // The daemon coming back is the moment a stale "unavailable" answer
        // should be replaced, not a minute later.
        store?.observe { [weak self, weak store] in
            guard let self, let store else { return }
            let available = store.health != nil
            if available, !self.daemonWasAvailable { Task { await self.refresh() } }
            self.daemonWasAvailable = available
        }
    }

    func start() {
        guard pollTask == nil else { return }
        daemonWasAvailable = store?.health != nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(60))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let fresh = try await client.state()
            // Snapshots repeat between daemon polls; only a change re-renders.
            if fresh != state { state = fresh }
            errorMessage = nil
        } catch {
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("plan_usage_load_failed", metadata: .fields(["error": error]))
        }
    }

    func setEnabled(_ enabled: Bool, for account: PlanUsageAccountID) async {
        guard !updating.contains(account) else { return }
        updating.insert(account)
        defer { updating.remove(account) }
        do {
            state = try await client.setEnabled(enabled, for: account)
            errorMessage = nil
        } catch {
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("plan_usage_switch_failed", metadata: .fields(["account": account.rawValue, "enabled": enabled, "error": error]))
        }
    }

    func account(_ id: PlanUsageAccountID) -> PlanUsageAccount? {
        state?.account(id)
    }
}

// MARK: - Notch display choices

/// One window the Notch can show, in the design's order (5 h → 7 d → model
/// window, Claude Code before Codex).
enum PlanUsageItem: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeSession
    case claudeWeekly
    case claudeFable
    case codexSession
    case codexWeekly

    var provider: AgentProvider {
        switch self {
        case .claudeSession, .claudeWeekly, .claudeFable: .claude
        case .codexSession, .codexWeekly: .codex
        }
    }

    var window: PlanUsageWindow {
        switch self {
        case .claudeSession, .codexSession: .session
        case .claudeWeekly, .claudeFable, .codexWeekly: .weekly
        }
    }

    var model: String? {
        self == .claudeFable ? "Fable" : nil
    }

    /// Top-bar label: units lowercase, model names as they are.
    var notchLabel: String {
        switch self {
        case .claudeSession, .codexSession: "5h"
        case .claudeWeekly, .codexWeekly: "7d"
        case .claudeFable: "Fable"
        }
    }

    /// Show pill under Settings › Notch › Usage.
    var pillTitle: String {
        switch self {
        case .claudeSession, .codexSession: "5-hour"
        case .claudeWeekly, .codexWeekly: "Weekly"
        case .claudeFable: "Fable"
        }
    }

    /// Short name inside the Notch tooltip.
    var shortTitle: String {
        switch self {
        case .claudeSession, .codexSession: "Session"
        case .claudeWeekly, .codexWeekly: "Weekly"
        case .claudeFable: "Fable"
        }
    }

    /// The design's default set: the three Claude windows and Codex weekly.
    static let defaults: Set<PlanUsageItem> = [.claudeSession, .claudeWeekly, .claudeFable, .codexWeekly]
}

enum PlanUsageAgentsMode: String, CaseIterable, Codable, Sendable {
    /// One agent at a time; a click on the cluster switches to the other.
    case switchOnClick
    case showBoth
}

enum PlanUsagePercentStyle: String, CaseIterable, Codable, Sendable {
    /// The provider's own figure.
    case used
    /// `100 − used`.
    case remaining
}

/// The Notch's plan-usage display choices, in `UserDefaults` under
/// `Lumi.Notch.PlanUsage.*`. Observable so the top bar, the Settings
/// section and its preview all move together. There is no master switch:
/// an empty item set is "off".
@MainActor
final class HaloPlanUsagePreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var agentsMode: PlanUsageAgentsMode { didSet { defaults.set(agentsMode.rawValue, forKey: Key.agentsMode) } }
    @Published var percentStyle: PlanUsagePercentStyle { didSet { defaults.set(percentStyle.rawValue, forKey: Key.percentStyle) } }
    @Published var items: Set<PlanUsageItem> { didSet { defaults.set(items.map(\.rawValue).sorted(), forKey: Key.items) } }
    /// `switchOnClick`: the agent last left on screen.
    @Published var selectedProvider: AgentProvider { didSet { defaults.set(selectedProvider.rawValue, forKey: Key.selectedProvider) } }

    private enum Key {
        static let agentsMode = "Lumi.Notch.PlanUsage.AgentsMode"
        static let percentStyle = "Lumi.Notch.PlanUsage.PercentStyle"
        static let items = "Lumi.Notch.PlanUsage.Items"
        static let selectedProvider = "Lumi.Notch.PlanUsage.SelectedProvider"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentsMode = defaults.string(forKey: Key.agentsMode).flatMap(PlanUsageAgentsMode.init(rawValue:)) ?? .showBoth
        percentStyle = defaults.string(forKey: Key.percentStyle).flatMap(PlanUsagePercentStyle.init(rawValue:)) ?? .used
        items = defaults.object(forKey: Key.items) == nil
            ? PlanUsageItem.defaults
            : Set((defaults.stringArray(forKey: Key.items) ?? []).compactMap(PlanUsageItem.init(rawValue:)))
        selectedProvider = defaults.string(forKey: Key.selectedProvider).flatMap(AgentProvider.init(rawValue:)) ?? .claude
    }

    func setItem(_ item: PlanUsageItem, on: Bool) {
        if on { items.insert(item) } else { items.remove(item) }
    }

    func toggle(_ item: PlanUsageItem) {
        setItem(item, on: !items.contains(item))
    }

    /// The choices as one value, for the pure presentation function.
    var snapshot: HaloPlanUsageChoices {
        HaloPlanUsageChoices(agentsMode: agentsMode, percentStyle: percentStyle, items: items, selectedProvider: selectedProvider)
    }
}

struct HaloPlanUsageChoices: Hashable, Sendable {
    var agentsMode: PlanUsageAgentsMode
    var percentStyle: PlanUsagePercentStyle
    var items: Set<PlanUsageItem>
    var selectedProvider: AgentProvider
}
