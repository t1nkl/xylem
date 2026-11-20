//
//  WindowToolbar.swift
//  Xylem
//
//  The window's native toolbar (unified compact style, set on the scene):
//  New Tab on the leading side; Model and Effort (this tab's Claude), then
//  the meters (the context ring and the plan's usage limits) in their own
//  capsule, Claude status, Usage and the inspector toggle on the trailing
//  side. The project is the window title (set by the terminals container),
//  so it needs no item.
//
//  Performance: every item that shows polled data is its own View and
//  reads AppModel itself, so a stats tick re-renders that item only -
//  never ContentView, which builds this toolbar.
//

import SwiftUI

struct WindowToolbar: ToolbarContent {
    let app: AppModel
    let updater: AppUpdater
    @Binding var showsInspector: Bool
    /// Off while the tabs are on top: their bar has its own "+".
    let showsNewTab: Bool
    let onNewTab: () -> Void
    let onOpenUsage: () -> Void

    /// The Claude status badge sits between the meters and Usage.
    private var showsStatusBadge: Bool {
        app.claudeStatus.status.map { !$0.isAllClear } ?? false
    }

    var body: some ToolbarContent {
        if showsNewTab {
            ToolbarItem(placement: .navigation) {
                Button(action: onNewTab) {
                    Label("New Tab", systemImage: "plus")
                }
                .help("New Tab (⌘T)")
            }
        }
        // An update waiting for a quit, in its own capsule before the
        // context and model one (the system's shared glass would merge it
        // into that capsule). Read here like the status badge: it changes at
        // most once per release.
        if let version = updater.readyVersion {
            ToolbarItem(placement: .primaryAction) {
                UpdateReadyBadge(version: version) { updater.checkForUpdates() }
                    .buttonStyle(.plain)
                    .frame(height: UpdateReadyBadge.height)
                    .contentShape(.capsule)
                    .modifier(OwnCapsuleGlass())
            }
            .sharedBackgroundHiddenIfAvailable()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ModelToolbarItem(app: app)
            EffortToolbarItem(app: app)
        }
        // Its own capsule: next to the model and effort the system would
        // merge it into theirs (see Usage below).
        ToolbarItem(placement: .primaryAction) {
            MetersToolbarItem(app: app)
                .frame(height: UpdateReadyBadge.height)
                // Not a button: glass that doesn't light up under the pointer.
                .modifier(OwnCapsuleGlass(interactive: false))
        }
        .sharedBackgroundHiddenIfAvailable()
        // Its own item so an all-clear status leaves no empty pill behind.
        // Reading the status here re-renders the window root, but the value
        // only changes when status.claude.com itself changes.
        if let status = app.claudeStatus.status, !status.isAllClear {
            ToolbarItem(placement: .primaryAction) {
                ClaudeStatusBadge(status: status)
            }
        }
        // Usage and the panel toggle are separate capsules. The system
        // merges neighbouring items into one glass capsule (Usage joins the
        // context and model one when no status badge sits between them),
        // and ToolbarSpacer(.fixed) adds no gap here in any placement.
        // Hiding the shared background puts an item in its own grouping
        // (Apple's docs); it draws its own capsule instead. macOS 15 has no
        // shared capsules, so Usage stays a system toolbar button there.
        ToolbarItem(placement: .primaryAction) {
            Group {
                if #available(macOS 26, *) {
                    // Right after the meters capsule (no status badge between)
                    // two own capsules touch; the extra room gives the
                    // system's gap, as for the panel toggle.
                    ToolbarIconCapsule(title: "Usage", systemImage: "chart.bar",
                                       leadingGap: showsStatusBadge ? 0 : 4, action: onOpenUsage)
                } else {
                    Button(action: onOpenUsage) {
                        Label("Usage", systemImage: "chart.bar")
                    }
                }
            }
            .help("Usage Dashboard (⌘U)")
        }
        .sharedBackgroundHiddenIfAvailable()
        ToolbarItem(placement: .primaryAction) {
            // Two own capsules side by side get half the system's gap
            // between groups; the extra room evens it out.
            ToolbarIconCapsule(title: "Inspector", systemImage: "sidebar.right", leadingGap: 4) {
                showsInspector.toggle()
            }
            .help(showsInspector ? "Hide the Claude / Git panel" : "Show the Claude / Git panel")
        }
        .sharedBackgroundHiddenIfAvailable()
    }
}

/// An icon-only toolbar button in its own glass capsule (Usage, the panel
/// toggle), for items whose shared background is hidden.
private struct ToolbarIconCapsule: View {
    let title: String
    let systemImage: String
    /// Extra room before the capsule, on macOS 26 only.
    var leadingGap: CGFloat = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                // The system capsules' height.
                .frame(width: 36, height: UpdateReadyBadge.height)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .modifier(OwnCapsuleGlass(leadingGap: leadingGap))
    }
}

/// The own glass capsule of the items that hide the shared background (macOS
/// 26), with optional room before it. macOS 15 has no Liquid Glass and draws
/// toolbar items without shared capsules, so the button stays plain there.
private struct OwnCapsuleGlass: ViewModifier {
    var leadingGap: CGFloat = 0
    var interactive = true

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
                .padding(.leading, leadingGap)
        } else {
            content
        }
    }
}

private extension ToolbarContent {
    /// Its own grouping on macOS 26 (see above); macOS 15 has no shared
    /// toolbar backgrounds to opt out of.
    @ToolbarContentBuilder func sharedBackgroundHiddenIfAvailable() -> some ToolbarContent {
        if #available(macOS 26, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

// MARK: - Meters

/// The context ring and, with a Claude plan, its usage limits: "◔ | ⌛ 5h 23%
/// · 7d 81%". Each part is its own View reading its own data, so a stats
/// tick re-renders the ring only.
private struct MetersToolbarItem: View {
    let app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ContextRingItem(app: app)
            if app.claudeStates.planLimits != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 1, height: 14)
                PlanLimitsToolbarItem(tracker: app.claudeStates)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// Context window fill of the active session as a ring; the percent used and
/// left and the tokens are in a tooltip shown at once on hover. An empty ring on picker tabs and while not
/// known.
struct ContextRingItem: View {
    let app: AppModel

    var body: some View {
        let session = app.activeSession
        let context = ContextReading.make(stats: session == nil ? nil : app.sessionStats.stats,
                                          live: session == nil ? nil : app.tabs.activeTab?.liveStatus)
        let fraction = context.fraction
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: Self.line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Self.color(for: fraction), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: Self.size, height: Self.size)
        .animation(.easeOut(duration: 0.4), value: fraction)
        // A tooltip at once: what is used and left is why one hovers here.
        .instantTooltip(Self.help(context))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(context.percent != nil ? context.display : "unknown")")
    }

    static let size: CGFloat = 15
    static let line: CGFloat = 3

    /// "Context: 43% used, 57% left (86K of 200K tokens)".
    nonisolated static func help(_ context: ContextReading) -> String {
        guard let percent = context.percent else { return "Context: not known until the next reply" }
        let used = Int(min(max(percent, 0), 100).rounded(.down))
        let text = "Context: \(used)% used, \(100 - used)% left"
        guard context.limit > 0 else { return text }
        return text + " (\(tokens(context.usedTokens)) of \(tokens(context.limit)) tokens)"
    }

    static func color(for fraction: CGFloat) -> Color {
        if fraction > 0.9 { return AppTheme.Colors.statusRed }
        if fraction > 0.7 { return AppTheme.Colors.statusAmber }
        return AppTheme.Colors.accent
    }

    /// 420000 → "420K", 1000000 → "1M".
    nonisolated static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if value >= 1_000 { return "\(value / 1_000)K" }
        return "\(value)"
    }
}

// MARK: - Model

/// Model menu: picking a family types `/model <alias>` into the active
/// session (see ModelSwitchController). Disabled on picker tabs and in
/// shells that were not started with claude.
private struct ModelToolbarItem: View {
    let app: AppModel

    var body: some View {
        let session = app.activeSession
        let stats = session == nil ? StatsSnapshot() : app.sessionStats.stats
        let shown = ModelSwitchController.displayedModel(
            pick: session.flatMap { app.modelSwitcher.picks[$0.id] },
            live: session == nil ? nil : app.tabs.activeTab?.liveStatus,
            stats: stats
        )
        // A fresh session has no reply yet: it runs the settings' default
        // model, so show that instead of a dash.
        let model = shown.title != nil
            ? shown
            : ModelSwitchController.defaultModelDisplay(app.environment.defaultModel)
        let canSwitch = session?.launchedClaude == true

        Menu {
            ForEach(ClaudeModelChoice.all) { choice in
                Button { app.switchModel(to: choice) } label: {
                    if choice == model.choice {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            // Own chevron right after the text and equal padding on both
            // sides: the system indicator sits at the capsule's far edge,
            // so any padding pushed it away from the title.
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                Text(session == nil ? "-" : (model.title ?? "-"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .menuIndicator(.hidden)
        .disabled(!canSwitch)
        .help(canSwitch
              ? "Switch the model of this Claude session (/model)"
              : "Open a Claude session to switch its model")
    }
}

// MARK: - Effort

/// Effort menu: shows the level the active session runs at (its status line
/// input, else the transcript) and sets a new one for that session only
/// (see ModelSwitchController). A dash while neither tells.
private struct EffortToolbarItem: View {
    let app: AppModel

    var body: some View {
        let session = app.activeSession
        let stats = session == nil ? StatsSnapshot() : app.sessionStats.stats
        let shown = session.flatMap {
            ModelSwitchController.displayedEffort(pick: app.modelSwitcher.effortPicks[$0.id],
                                                  live: app.tabs.activeTab?.liveStatus, stats: stats)
        }
        // Claude Code's version from the status line: levels it can't set
        // for one session sit greyed under a short header; with no `/effort`
        // at all the menu is off and the tooltip says why.
        let version = session == nil ? nil : app.tabs.activeTab?.liveStatus?.version
        let canSwitch = session?.launchedClaude == true && EffortSupport.canSetAnything(version: version)
        let available = ClaudeEffortChoice.levels.filter { EffortSupport.isAvailable($0, version: version) }
        let unavailable = ClaudeEffortChoice.levels.filter { !available.contains($0) }

        Menu {
            if !unavailable.isEmpty {
                Section(EffortSupport.unavailableHeader) {
                    ForEach(unavailable) { choice in item(choice, shown: shown).disabled(true) }
                }
            }
            ForEach(available) { choice in item(choice, shown: shown) }
        } label: {
            // Same layout as the model menu's label.
            HStack(spacing: 5) {
                Image(systemName: "brain")
                Text(shown?.title ?? "-")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
        }
        .menuIndicator(.hidden)
        .disabled(!canSwitch)
        .help(Self.help(canSwitch: canSwitch, shown: shown, version: version))
        .accessibilityLabel("Effort \(shown?.title ?? "unknown")")
    }

    private func item(_ choice: ClaudeEffortChoice, shown: ClaudeEffortChoice?) -> some View {
        Button { app.switchEffort(to: choice) } label: {
            if choice == shown {
                Label(choice.title, systemImage: "checkmark")
            } else {
                Text(choice.title)
            }
        }
    }

    private static func help(canSwitch: Bool, shown: ClaudeEffortChoice?, version: String?) -> String {
        if let version, !EffortSupport.canSetAnything(version: version) { return EffortSupport.cantSetHelp(version: version) }
        guard canSwitch else { return "Open a Claude session to set its effort" }
        guard shown != nil else {
            return "Effort: not known yet. Pick a level to set it for this session"
        }
        return "Set the effort of this Claude session only (/effort)"
    }
}

// MARK: - Plan limits

/// The plan's usage limits as Claude Code reports them (5-hour and weekly
/// windows, percent used): "7d 44%". Shown by the meters only when there
/// are some (none for API keys, before a request, past every reset).
/// Account-wide: the same in every tab.
private struct PlanLimitsToolbarItem: View {
    let tracker: ClaudeTabStateTracker

    var body: some View {
        if let limits = tracker.planLimits {
            let windows = Self.windows(limits)
            HStack(spacing: 5) {
                Image(systemName: "hourglass")
                ForEach(windows, id: \.name) { window in
                    if window.name != windows.first?.name {
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text("\(window.name) \(Self.percent(window.value.usedPercentage))")
                        .monospacedDigit()
                        .foregroundStyle(Self.color(for: window.value.usedPercentage))
                }
            }
            .instantTooltip(Self.help(windows, reportedAt: tracker.planLimitsReportedAt))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plan usage: " + windows.map { "\($0.title) \(Self.percent($0.value.usedPercentage))" }
                .joined(separator: ", "))
        }
    }

    struct Shown {
        let name: String
        let title: String
        let value: ClaudeLiveStatus.RateLimits.Window
    }

    static func windows(_ limits: ClaudeLiveStatus.RateLimits) -> [Shown] {
        var shown: [Shown] = []
        if let five = limits.fiveHour { shown.append(Shown(name: "5h", title: "5-hour", value: five)) }
        if let week = limits.sevenDay { shown.append(Shown(name: "7d", title: "weekly", value: week)) }
        return shown
    }

    static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    static func color(for percent: Double) -> Color {
        if percent >= 90 { return AppTheme.Colors.statusRed }
        if percent >= 70 { return AppTheme.Colors.statusAmber }
        return .secondary
    }

    static func help(_ windows: [Shown], reportedAt: Date?, now: Date = Date()) -> String {
        var lines = ["Plan usage limits (from Claude Code)"]
        for window in windows {
            var line = "\(window.title.prefix(1).uppercased() + window.title.dropFirst()): \(percent(window.value.usedPercentage)) used"
            if let reset = window.value.resetsAt { line += ", resets " + dayTime(reset, now: now, todayPrefix: "at ") }
            lines.append(line)
        }
        // Claude Code reports them with its requests: an idle Mac shows the last ones.
        if let reportedAt { lines.append("As of " + dayTime(reportedAt, now: now)) }
        return lines.joined(separator: "\n")
    }

    /// "14:10" today (after `todayPrefix`), else "Mon 09:00".
    static func dayTime(_ date: Date, now: Date, todayPrefix: String = "") -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return todayPrefix + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
