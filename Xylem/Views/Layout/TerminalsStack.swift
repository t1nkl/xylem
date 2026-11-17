//
//  TerminalsStack.swift
//  Xylem
//
//  Renders each tab's terminal (or its picker) in a ZStack, showing only
//  the active tab. Running sessions inside hidden tabs stay attached so
//  scrollback and child processes survive tab switches. Opacity alone only
//  hides them from the eye - `isActive` goes down to TerminalRepresentable
//  so AppKit also stops drawing them and moves keyboard focus.
//

import SwiftUI

struct TerminalsStack: View {
    let tabs: [TerminalTab]
    let activeTabID: TerminalTab.ID?
    let recentProjects: [ClaudeProject]
    var onPickFolder: (TerminalTab.ID, String) -> Void = { _, _ in }
    var onPickProject: (TerminalTab.ID, ClaudeProject) -> Void = { _, _ in }

    var body: some View {
        ZStack {
            ForEach(tabs) { tab in
                TabContent(
                    tab: tab,
                    isActive: tab.id == activeTabID,
                    recentProjects: recentProjects,
                    onPickFolder: { onPickFolder(tab.id, $0) },
                    onPickProject: { onPickProject(tab.id, $0) }
                )
                .opacity(tab.id == activeTabID ? 1 : 0)
                .allowsHitTesting(tab.id == activeTabID)
            }
        }
        .background(AppTheme.Colors.terminalBackground)
    }
}

private struct TabContent: View {
    let tab: TerminalTab
    let isActive: Bool
    let recentProjects: [ClaudeProject]
    let onPickFolder: (String) -> Void
    let onPickProject: (ClaudeProject) -> Void

    var body: some View {
        switch tab.state {
        case .picker:
            NewTabPickerView(
                recentProjects: recentProjects,
                onOpenFolder: onPickFolder,
                onOpenRecent: onPickProject
            )
        case .session(let session):
            TerminalRepresentable(session: session, isActive: isActive)
                .overlay { TerminalStartingOverlay(session: session) }
        }
    }
}
