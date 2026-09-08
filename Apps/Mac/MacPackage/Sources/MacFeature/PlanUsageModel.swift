import Core
import Diagnostics
import Logging
import Transport
import Foundation

private let log = Logger(label: "ui")

/// The Mac's copy of the daemon's plan-usage snapshot and of the settings
/// that shape it (which accounts are polled, whether a percentage reads as
/// used or remaining), shared by Settings › Usage › Plan, Settings › Notch ›
/// Usage and the Notch top bar. Polled every minute for as long as the app
/// runs — the Notch is always on screen — and at once when the daemon comes
/// back. Settings are written through the daemon (`set_settings`) so every
/// device reads the same value.
@MainActor
final class PlanUsageModel: ObservableObject {
    @Published private(set) var state: PlanUsageState?
    /// The daemon's settings as last read or stored; defaults until the
    /// first answer.
    @Published private(set) var settings: DaemonSettings = .defaults
    /// The first successful `get_settings` happened: writes may proceed
    /// (a write before that would clobber the daemon's switches with defaults).
    @Published private(set) var settingsLoaded = false
    /// The last failure, cleared by the next successful load.
    @Published private(set) var errorMessage: String?
    /// Accounts with a switch in flight; their toggles are disabled meanwhile.
    @Published private(set) var updating: Set<PlanUsageAccountID> = []
    /// How the Notch shows the numbers — the Mac's own choices.
    let preferences: HaloPlanUsagePreferences
    /// Before the settings table, the percent style was a Mac defaults key;
    /// the first successful load carries it over once and removes it.
    private let legacyDefaults: UserDefaults
    static let legacyPercentStyleKey = "Lumi.Notch.PlanUsage.PercentStyle"

    private let client: PlanUsageClient
    private weak var store: MacSessionStore?
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var daemonWasAvailable = false

    init(
        client: PlanUsageClient = PlanUsageClient(),
        store: MacSessionStore? = nil,
        pollInterval: Duration = .seconds(60),
        preferences: HaloPlanUsagePreferences = HaloPlanUsagePreferences(),
        legacyDefaults: UserDefaults = .standard
    ) {
        self.client = client
        self.store = store
        self.pollInterval = pollInterval
        self.preferences = preferences
        self.legacyDefaults = legacyDefaults
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

    var percentStyle: PlanUsagePercentStyle { settings.planUsage.percentStyle }

    func refresh() async {
        do {
            let fresh = try await client.state()
            // Snapshots repeat between daemon polls; only a change re-renders.
            if fresh != state { state = fresh }
            errorMessage = nil
        } catch {
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("plan_usage_load_failed", metadata: .fields(["error": error]))
            return
        }
        do {
            let fresh = try await client.settings()
            if fresh != settings { settings = fresh }
            settingsLoaded = true
            await importLegacyPercentStyle()
        } catch {
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("settings_load_failed", metadata: .fields(["error": error]))
        }
    }

    func setEnabled(_ enabled: Bool, for account: PlanUsageAccountID) async {
        guard !updating.contains(account) else { return }
        updating.insert(account)
        defer { updating.remove(account) }
        var next = settings
        next.planUsage.enabledAccounts.removeAll { $0 == account }
        if enabled { next.planUsage.enabledAccounts.append(account) }
        guard await save(next, reason: "switch") else { return }
        // The daemon fetched the account while storing the switch; show it.
        if let fresh = try? await client.state(), fresh != state { state = fresh }
    }

    func setPercentStyle(_ style: PlanUsagePercentStyle) async {
        var next = settings
        next.planUsage.percentStyle = style
        _ = await save(next, reason: "percent_style")
    }

    /// `set_settings`; the stored answer replaces the local copy.
    @discardableResult
    private func save(_ next: DaemonSettings, reason: String) async -> Bool {
        guard settingsLoaded else {
            errorMessage = "Settings have not been read from the daemon yet."
            log.warning("settings_save_skipped", metadata: .fields(["reason": reason]))
            return false
        }
        do {
            settings = try await client.save(next)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? IPCFailure)?.message ?? error.localizedDescription
            log.warning("settings_save_failed", metadata: .fields(["reason": reason, "error": error]))
            return false
        }
    }

    private func importLegacyPercentStyle() async {
        guard let raw = legacyDefaults.string(forKey: Self.legacyPercentStyleKey) else { return }
        legacyDefaults.removeObject(forKey: Self.legacyPercentStyleKey)
        guard let style = PlanUsagePercentStyle(rawValue: raw), style != settings.planUsage.percentStyle else { return }
        log.info("settings_legacy_percent_style_imported", metadata: .fields(["percent_style": raw]))
        await setPercentStyle(style)
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

/// The Notch's own plan-usage display choices, in `UserDefaults` under
/// `Lumi.Notch.PlanUsage.*` — Mac-only choices (the percent style is a
/// daemon setting, see `PlanUsageModel.settings`). Observable so the top
/// bar, the Settings section and its preview all move together. There is no
/// master switch: an empty item set is "off".
@MainActor
final class HaloPlanUsagePreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published var agentsMode: PlanUsageAgentsMode { didSet { defaults.set(agentsMode.rawValue, forKey: Key.agentsMode) } }
    @Published var items: Set<PlanUsageItem> { didSet { defaults.set(items.map(\.rawValue).sorted(), forKey: Key.items) } }
    /// `switchOnClick`: the agent last left on screen.
    @Published var selectedProvider: AgentProvider { didSet { defaults.set(selectedProvider.rawValue, forKey: Key.selectedProvider) } }

    private enum Key {
        static let agentsMode = "Lumi.Notch.PlanUsage.AgentsMode"
        static let items = "Lumi.Notch.PlanUsage.Items"
        static let selectedProvider = "Lumi.Notch.PlanUsage.SelectedProvider"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agentsMode = defaults.string(forKey: Key.agentsMode).flatMap(PlanUsageAgentsMode.init(rawValue:)) ?? .showBoth
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

    /// The choices as one value, for the pure presentation function; the
    /// percent style comes from the daemon's settings.
    func snapshot(percentStyle: PlanUsagePercentStyle) -> HaloPlanUsageChoices {
        HaloPlanUsageChoices(agentsMode: agentsMode, percentStyle: percentStyle, items: items, selectedProvider: selectedProvider)
    }
}

struct HaloPlanUsageChoices: Hashable, Sendable {
    var agentsMode: PlanUsageAgentsMode
    var percentStyle: PlanUsagePercentStyle
    var items: Set<PlanUsageItem>
    var selectedProvider: AgentProvider
}
