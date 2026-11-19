//
//  WindowToolbar.swift
//  Xylem
//
//  The window's native toolbar (unified compact style, set on the scene):
//  New Tab on the leading side; Context, Model and Claude status, then
//  Usage and the inspector toggle on the trailing side. The project is the
//  window title (set by the terminals container), so it needs no item.
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
            ContextToolbarItem(app: app)
            ModelToolbarItem(app: app)
        }
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
                    ToolbarIconCapsule(title: "Usage", systemImage: "chart.bar", action: onOpenUsage)
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

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
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

// MARK: - Context

/// Context window fill of the active session: a capacity gauge and the
/// percentage. Empty (a dash) on picker tabs.
private struct ContextToolbarItem: View {
    let app: AppModel

    var body: some View {
        let stats = app.activeSession == nil ? StatsSnapshot() : app.sessionStats.stats
        let fraction = stats.contextFraction
        HStack(spacing: 6) {
            Gauge(value: Double(fraction)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(Self.color(for: fraction))
                .frame(width: 56)
            Text(stats.hasUsageData ? stats.contextDisplay : "-")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        // Room between the text and the edges of the toolbar capsule.
        .padding(.horizontal, 12)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .help(stats.hasUsageData
              ? "Context: \(Self.tokens(stats.contextUsed)) of \(Self.tokens(stats.contextLimit)) tokens"
              : "Context: no data yet")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(stats.hasUsageData ? stats.contextDisplay : "unknown")")
    }

    static func color(for fraction: CGFloat) -> Color {
        if fraction > 0.9 { return AppTheme.Colors.statusRed }
        if fraction > 0.7 { return AppTheme.Colors.statusAmber }
        return AppTheme.Colors.accent
    }

    /// 420000 → "420K", 1000000 → "1M".
    static func tokens(_ value: Int) -> String {
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
