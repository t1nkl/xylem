//
//  PanelRail.swift
//  Xylem
//
//  The icon column at the window's right edge, never moving: Claude and
//  Git switch the right panel (and show it, or hide it when already
//  showing that), Files and Changes open the drawer over the terminal.
//  Icons only, each with
//  a tooltip. Wiring: PanelRailContainer in RightPanel.swift.
//

import SwiftUI

enum PanelRailItem: String, CaseIterable, Identifiable {
    case claude, git, files, changes
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .claude: "sparkles"
        case .git: "arrow.triangle.branch"
        case .files: "folder"
        case .changes: "plusminus"
        }
    }

    var tooltip: String {
        switch self {
        case .claude: "Claude: directories, sessions, skills, agents, MCP"
        case .git: "Git: branches, worktrees, commits"
        case .files: "Files: browse the project's folders"
        case .changes: "Changes: modified files and their diffs"
        }
    }
}

struct PanelRail: View {
    /// Which items show as selected (the panel's tab while it is visible,
    /// the drawer's mode while it is open).
    let selected: Set<PanelRailItem>
    let onSelect: (PanelRailItem) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(PanelRailItem.allCases) { item in
                PanelRailButton(item: item, isSelected: selected.contains(item)) { onSelect(item) }
                if item == .git {
                    // Panel tabs above, drawers below.
                    Rectangle().fill(AppTheme.Colors.panelBorder).frame(width: 26, height: 1).padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: AppTheme.Metrics.panelRailWidth)
        .frame(maxHeight: .infinity)
        .background(AppTheme.Colors.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.Colors.panelBorder).frame(width: 1)
        }
    }
}

private struct PanelRailButton: View {
    let item: PanelRailItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: item.icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(isSelected || isHovering ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .frame(width: 40, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isSelected ? 0.14 : (isHovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.tooltip)
        .accessibilityLabel(item.tooltip)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
