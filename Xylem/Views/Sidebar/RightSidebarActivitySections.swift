//
//  RightSidebarActivitySections.swift
//  Xylem
//
//  Activity sections of the right panel: Sessions, Directories, Agent
//  Teams. Each is its own view and reads only the data it renders.
//

import SwiftUI
import AppKit

// MARK: - Sessions

/// The active project's sessions in "This project" mode, the newest across
/// every project in "All" mode (or when no project is open).
struct SessionsSection: View {
    let sessionList: SessionListViewModel
    let environment: ClaudeEnvironmentViewModel
    let onSelect: (ClaudeSession) -> Void

    @State private var showsAll = false
    private let collapsedLimit = 8

    private var isProjectScoped: Bool {
        environment.scope == .project && sessionList.projectDirectory != nil
    }

    var body: some View {
        let sessions = isProjectScoped ? sessionList.projectSessions : sessionList.sessions
        let visible = showsAll ? sessions : Array(sessions.prefix(collapsedLimit))
        let remaining = max(0, sessions.count - collapsedLimit)

        SidebarSection(title: "Sessions", count: sessions.count) {
            if sessions.isEmpty {
                EmptyStateView(
                    icon: "bubble.left.and.text.bubble.right",
                    message: isProjectScoped ? "No Claude sessions in this project yet." : "No Claude sessions yet."
                )
            } else {
                SessionsListView(sessions: visible, onSelect: onSelect)
                if remaining > 0 {
                    ShowMoreButton(isExpanded: showsAll, remaining: remaining, onToggle: { showsAll.toggle() })
                }
            }
        }
    }
}

// MARK: - Directories

/// Every project Claude Code has seen. Never filtered by scope.
struct DirectoriesSection: View {
    let sessionList: SessionListViewModel
    let onSelectProject: (ClaudeProject) -> Void

    @State private var showsAll = false
    private let collapsedLimit = 6

    var body: some View {
        let projects = sessionList.projects
        let visible = showsAll ? projects : Array(projects.prefix(collapsedLimit))
        let remaining = max(0, projects.count - collapsedLimit)

        SidebarSection(
            title: "Directories",
            count: projects.count,
            defaultExpanded: true,
            trailingAction: .plus(tooltip: "Open a folder", action: pickAndOpenFolder)
        ) {
            ForEach(visible) { project in
                projectRow(project)
            }
            if remaining > 0 {
                ShowMoreButton(isExpanded: showsAll, remaining: remaining, onToggle: { showsAll.toggle() })
            }
            if projects.isEmpty {
                EmptyStateView(
                    icon: "folder.badge.plus",
                    message: "No projects opened yet.",
                    cta: .init(label: "Open Folder…", action: pickAndOpenFolder)
                )
            }
        }
    }

    private func projectRow(_ project: ClaudeProject) -> some View {
        Button(action: { onSelectProject(project) }) {
            SidebarListItem(title: project.displayName, detail: "\(project.sessionCount)", isInteractive: true)
        }
        .buttonStyle(.plain)
        .help(project.path)
        .accessibilityLabel(project.displayName)
        .contextMenu {
            Button("Open in New Tab") { onSelectProject(project) }
            Divider()
            Button("Copy Path") { SidebarClipboard.copy(project.path) }
            Button("Reveal in Finder") { SidebarClipboard.revealInFinder(project.path) }
        }
    }

    private func pickAndOpenFolder() {
        guard let url = OpenPanels.pick(.projectFolder) else { return }
        onSelectProject(ClaudeProject(
            id: url.lastPathComponent,
            path: url.path,
            displayName: url.lastPathComponent,
            sessionCount: 0,
            lastModified: .now
        ))
    }
}

// MARK: - Agent teams

/// Claude Code agent teams from `~/.claude/teams/*/config.json`. Teams come
/// and go while Claude runs, so the list is re-read every 15 s - only while
/// this section is on screen, and cheaply (configs are cached by mtime).
struct AgentTeamsSection: View {
    let store: AgentTeamsStore

    var body: some View {
        let teams = store.teams
        SidebarSection(title: "Agent Teams", count: teams.count) {
            if teams.isEmpty {
                EmptyStateView(icon: "person.3", message: "No active agent teams.")
            } else {
                ForEach(teams) { team in
                    teamGroup(team)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                store.reloadLast()
            }
        }
    }

    private func teamGroup(_ team: AgentTeam) -> some View {
        DisclosureGroup {
            ForEach(team.members, id: \.name) { member in
                SidebarListItem(title: member.name, detail: member.agentType)
            }
        } label: {
            SidebarGroupLabel(icon: "person.3.fill", name: team.name, count: team.members.count)
        }
        .disclosureGroupStyle(CompactDisclosureStyle())
        .help(team.leadCwd ?? team.name)
    }
}

/// Label of a nested group (plugin skills, agent team): secondary name and
/// muted count, matching the "TITLE n" rhythm of section headers.
struct SidebarGroupLabel: View {
    let icon: String
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(name)
                .font(AppTheme.Fonts.sectionItem)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(count)")
                .font(AppTheme.Fonts.sectionMeta)
                .foregroundStyle(AppTheme.Colors.textMuted)
            Spacer(minLength: 0)
        }
    }
}
