//
//  RightSidebarView.swift
//  Xylem
//
//  Right-side panel with Claude and Git tabs, picked on the panel rail and
//  hosted by RightPanelContainer (width, background, divider; RightPanel.swift).
//  Compact density.
//
//  Every section is its own view struct that reads only its own observable
//  property (see ClaudeEnvironmentViewModel), so a reload that changes one
//  list re-renders one section - not the whole panel, as it did when all
//  sections shared one body. The panel's scope ("This project" / "All")
//  filters sessions, plugins, skills, agents, MCP, permissions, hooks and
//  agent teams; Directories always lists every project.
//
//  Section files:
//    · RightSidebarActivitySections.swift - Sessions / Directories / Agent Teams
//    · RightSidebarConfigSections.swift   - Skills / Agents / MCP / Plugins / Permissions / Hooks
//

import SwiftUI
import AppKit

/// Everything the panel can ask the app to do. Plain closures so the panel
/// stays presentational.
struct RightSidebarActions {
    var selectSession: (ClaudeSession) -> Void = { _ in }
    var selectProject: (ClaudeProject) -> Void = { _ in }
    var runInActiveTab: (String) -> Void = { _ in }
    var openSkillsDirectory: () -> Void = {}
    var newWorktree: () -> Void = {}
    var openWorktree: (String) -> Void = { _ in }
    var scopeChanged: () -> Void = {}
}

struct RightSidebarView: View {
    let sessionList: SessionListViewModel
    let environment: ClaudeEnvironmentViewModel
    let gitStatus: GitStatusViewModel
    let agentTeams: AgentTeamsStore
    /// True when the active tab runs claude - gates the "+" and CTAs that
    /// send slash commands to it (Run /mcp, Run /plugin).
    let hasActiveSession: Bool
    /// Whether the panel is shown. It stays alive while hidden (zero width,
    /// so its sections keep their state), so the Git panel needs this to
    /// stop git work.
    var isPresented: Bool = true
    var actions = RightSidebarActions()
    /// Claude or Git, picked on the panel rail (`PanelRail`) - the panel
    /// has no switcher of its own any more (2026-11-16).
    var tab: SidebarTab = .claude

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .claude:
                claudeContent
            case .git:
                GitPanel(gitStatus: gitStatus, isPresented: isPresented, actions: actions)
            }
        }
        // The Claude/Git switcher used to sit here; keep its breathing room.
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var claudeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SidebarScopeBanner(environment: environment, onScopeChanged: actions.scopeChanged)
                // Directories first and the only section open by default;
                // everything else starts collapsed (design choice).
                DirectoriesSection(sessionList: sessionList, onSelectProject: actions.selectProject)
                SessionsSection(sessionList: sessionList, environment: environment, onSelect: actions.selectSession)
                AgentTeamsSection(store: agentTeams)
                SkillsSection(environment: environment, onOpenSkillsDirectory: actions.openSkillsDirectory)
                AgentsSection(environment: environment)
                McpSection(environment: environment, hasActiveSession: hasActiveSession, onRunInActiveTab: actions.runInActiveTab)
                PluginsSection(environment: environment, hasActiveSession: hasActiveSession, onRunInActiveTab: actions.runInActiveTab)
                PermissionsSection(environment: environment)
                HooksSection(environment: environment)
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.never)
    }

    enum SidebarTab: String, CaseIterable {
        case claude, git

        var title: String {
            switch self {
            case .claude: return "Claude"
            case .git: return "Git"
            }
        }
    }
}

// MARK: - Header pieces

/// The This project / All switch; just "Global" when no project is open.
private struct SidebarScopeBanner: View {
    @Bindable var environment: ClaudeEnvironmentViewModel
    let onScopeChanged: () -> Void

    var body: some View {
        // With a project open, its name is already the window title: the
        // switch gets the full width (a label next to it was truncated to
        // "Proj…r-api"). Without one everything is global.
        Group {
            if environment.currentDirectory != nil {
                PanelSegmentedControl(
                    options: SidebarScope.allCases,
                    selection: $environment.scope,
                    title: \.title
                )
                .help("Show only what belongs to this project, or everything Claude can use here")
            } else {
                Label(environment.scopeLabel, systemImage: "globe")
                    .font(AppTheme.Fonts.sectionMeta)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SidebarLayout.gutter)
        .frame(height: 30)
        .onChange(of: environment.scope) { onScopeChanged() }
    }
}

// MARK: - Git

/// Reads the git view model itself (status, loading, directory), so git
/// updates never re-render the Claude tab or the window root. Tells the
/// view model when it is on screen - the Git tab is selected AND the
/// panel is shown - so git only runs while visible.
private struct GitPanel: View {
    let gitStatus: GitStatusViewModel
    let isPresented: Bool
    let actions: RightSidebarActions

    var body: some View {
        GitTabView(
            status: gitStatus.status,
            directory: gitStatus.currentDirectory,
            isLoading: gitStatus.isLoading,
            onRefresh: {
                Task { await gitStatus.refresh(for: gitStatus.currentDirectory, force: true) }
            },
            onRunInActiveTab: actions.runInActiveTab,
            onNewWorktree: actions.newWorktree,
            onOpenWorktree: actions.openWorktree
        )
        .task(id: isPresented) { await gitStatus.setVisible(isPresented) }
        .onDisappear { Task { await gitStatus.setVisible(false) } }
    }
}

// MARK: - Shared helpers

enum SidebarClipboard {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}
