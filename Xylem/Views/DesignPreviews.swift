//
//  DesignPreviews.swift
//  Xylem
//
//  Fixture-only previews of the window chrome. Nothing here spawns a shell
//  or Claude: tabs are pickers and the terminal is a static stand-in with
//  the right colours.
//

#if DEBUG
import SwiftUI

private struct TerminalStandIn: View {
    private let lines: [(String, Color)] = [
        ("╭───────────────────────────────────────────────╮", Color(white: 0.45)),
        ("│ ✻ Welcome to Claude Code                       │", Color(red: 0.85, green: 0.47, blue: 0.34)),
        ("╰───────────────────────────────────────────────╯", Color(white: 0.45)),
        ("", .clear),
        ("> check why the billing-api test fails", Color(white: 0.92)),
        ("", .clear),
        ("● Read(app/Services/BillingService.php)", Color(white: 0.80)),
        ("  ⎿  Read 214 lines", Color(white: 0.55)),
        ("● Bash(php artisan test --filter=Webhook)", Color(white: 0.80)),
        ("  ⎿  Tests: 12 passed (48 assertions)", Color(red: 0.29, green: 0.87, blue: 0.50))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.0.isEmpty ? " " : line.0)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(line.1)
            }
            Spacer()
            Text("> ")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(white: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .background(Color(red: 0.216, green: 0.216, blue: 0.216))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.Colors.terminalBackground)
    }
}

/// The native shell on fixtures: tab sidebar, terminal stand-in with the
/// bottom bar, a stand-in right panel and the panel rail. The window toolbar
/// needs AppModel, so it is not part of this preview; run the app to see it.
private struct ChromePreview: View {
    let tabs: [TerminalTab] = [
        TerminalTab(title: "billing-api", state: .picker),
        TerminalTab(title: "search-api", state: .picker),
        TerminalTab(title: "app", state: .picker)
    ]

    var body: some View {
        NavigationSplitView {
            LeftTabSidebar(tabs: tabs, activeTabID: tabs[0].id)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TerminalStandIn()
                    BottomToolbar(actions: BottomToolbarActions(), doctorStatus: { .healthy(path: "/Users/dev/.local/bin/claude") })
                }
                RightPanelContainer(isShown: true) {
                    Text("right panel - see RightSidebarView previews")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                PanelRail(selected: [.claude], onSelect: { _ in })
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview("Window chrome", traits: .fixedLayout(width: 1400, height: 820)) {
    ChromePreview()
}

private let previewProjects: [ClaudeProject] = [
    ClaudeProject(id: "a", path: "/Users/dev/Sites/app", displayName: "app",
                  sessionCount: 82, lastModified: .now.addingTimeInterval(-600)),
    ClaudeProject(id: "b", path: "/Users/dev/Code/acme/billing-api", displayName: "billing-api",
                  sessionCount: 17, lastModified: .now.addingTimeInterval(-7_200))
]

#Preview("New tab picker", traits: .fixedLayout(width: 1000, height: 700)) {
    NewTabPickerView(recentProjects: previewProjects)
        .background(AppTheme.Colors.terminalBackground)
        .preferredColorScheme(.dark)
}

#Preview("Command palette", traits: .fixedLayout(width: 640, height: 460)) {
    CommandPaletteSheet(
        commands: [
            PaletteCommand(id: "new", title: "New Tab", subtitle: nil, keywords: [], icon: "plus", shortcut: "⌘T", run: {}),
            PaletteCommand(id: "usage", title: "Usage Dashboard", subtitle: "Cost and tokens", keywords: [], icon: "chart.bar", shortcut: "⌘U", run: {}),
            PaletteCommand(id: "compact", title: "Compact", subtitle: "/compact", keywords: [], icon: "rectangle.compress.vertical", shortcut: nil, run: {})
        ],
        onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Keyboard cheatsheet", traits: .fixedLayout(width: 620, height: 560)) {
    KeyboardCheatsheet(onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Onboarding", traits: .fixedLayout(width: 720, height: 560)) {
    OnboardingSheet()
        .preferredColorScheme(.dark)
}

#Preview("Settings", traits: .fixedLayout(width: 620, height: 520)) {
    SettingsView(updater: AppUpdater())
        .preferredColorScheme(.dark)
}
#endif
