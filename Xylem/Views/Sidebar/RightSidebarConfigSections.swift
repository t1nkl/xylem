//
//  RightSidebarConfigSections.swift
//  Xylem
//
//  Configuration sections of the right panel: Skills, Agents, MCP, Plugins,
//  Permissions, Hooks. Each reads one already-filtered, already-grouped
//  property of ClaudeEnvironmentViewModel, so nothing is sorted or grouped
//  inside `body` and a change re-renders only its own section.
//

import SwiftUI
import AppKit

// MARK: - Skills

struct SkillsSection: View {
    let environment: ClaudeEnvironmentViewModel
    let onOpenSkillsDirectory: () -> Void

    var body: some View {
        let skills = environment.skills
        SidebarSection(
            title: "Skills",
            count: skills.count,
            trailingAction: .plus(tooltip: "Browse skills.sh directory", action: onOpenSkillsDirectory)
        ) {
            if skills.isEmpty {
                EmptyStateView(
                    icon: "sparkles",
                    message: ScopeCopy.empty("skills", environment: environment),
                    cta: .init(label: "Browse skills.sh", action: onOpenSkillsDirectory)
                )
            } else {
                // User and project skills flat; plugin skills grouped per plugin.
                ForEach(skills.flat) { skill in
                    SidebarListItem(title: skill.name, detail: skill.scope.rawValue)
                }
                ForEach(skills.groups) { group in
                    DisclosureGroup {
                        ForEach(group.members) { skill in
                            SidebarListItem(title: skill.name, detail: nil)
                        }
                    } label: {
                        SidebarGroupLabel(icon: "puzzlepiece.extension.fill", name: group.name, count: group.members.count)
                    }
                    .disclosureGroupStyle(CompactDisclosureStyle())
                }
            }
        }
    }
}

// MARK: - Agents

struct AgentsSection: View {
    let environment: ClaudeEnvironmentViewModel

    var body: some View {
        let agents = environment.agents
        SidebarSection(title: "Agents", count: agents.count) {
            if agents.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle.badge.plus",
                    message: ScopeCopy.empty("agents", environment: environment),
                    cta: emptyCTA
                )
            } else {
                // Team-less agents flat; agents with a team (frontmatter or
                // plugin) under a collapsible sub-heading.
                ForEach(agents.flat) { agent in
                    AgentRow(agent: agent)
                }
                ForEach(agents.groups) { team in
                    DisclosureGroup {
                        ForEach(team.members) { agent in AgentRow(agent: agent) }
                    } label: {
                        SidebarGroupLabel(icon: "person.3.fill", name: team.name, count: team.members.count)
                    }
                    .disclosureGroupStyle(CompactDisclosureStyle())
                }
            }
        }
    }

    /// Offers to reveal the project's `.claude/agents/` folder (created if
    /// missing) so the user can drop agent markdown files in.
    private var emptyCTA: EmptyStateView.CTA? {
        guard let project = environment.currentDirectory else { return nil }
        let folder = URL(fileURLWithPath: project).appending(path: ".claude/agents")
        return .init(label: "Open .claude/agents folder") {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

private struct AgentRow: View {
    let agent: InstalledAgent

    var body: some View {
        SidebarListItem(title: agent.name, detail: agent.scope == .plugin ? agent.pluginName : agent.scope.rawValue)
            .help(agent.description ?? agent.fileURL.path)
            .contextMenu {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(agent.fileURL.path, inFileViewerRootedAtPath: "")
                }
                Button("Copy Path") { SidebarClipboard.copy(agent.fileURL.path) }
            }
    }
}

// MARK: - MCP

struct McpSection: View {
    let environment: ClaudeEnvironmentViewModel
    let hasActiveSession: Bool
    let onRunInActiveTab: (String) -> Void

    var body: some View {
        let servers = environment.mcpServers
        SidebarSection(
            title: "MCP",
            count: servers.count,
            // Only with claude running in the active tab: on a picker tab
            // the command had nowhere to go and was silently dropped.
            trailingAction: hasActiveSession
                ? .plus(tooltip: "Add MCP server via `/mcp` in the active tab", action: { onRunInActiveTab("/mcp") })
                : nil
        ) {
            ForEach(servers) { server in
                SidebarListItem(
                    title: server.name,
                    detail: SidebarFormat.mcpDetail(server),
                    accent: SidebarFormat.accent(for: server.scope)
                )
            }
            if servers.isEmpty {
                EmptyStateView(
                    icon: "server.rack",
                    message: ScopeCopy.empty("MCP servers", environment: environment),
                    cta: hasActiveSession ? .init(label: "Run /mcp in active tab", action: { onRunInActiveTab("/mcp") }) : nil
                )
            }
        }
    }
}

// MARK: - Plugins

struct PluginsSection: View {
    let environment: ClaudeEnvironmentViewModel
    let hasActiveSession: Bool
    let onRunInActiveTab: (String) -> Void

    var body: some View {
        let plugins = environment.plugins
        SidebarSection(
            title: "Plugins",
            count: plugins.count,
            // Only with claude running in the active tab: on a picker tab
            // the command had nowhere to go and was silently dropped.
            trailingAction: hasActiveSession
                ? .plus(tooltip: "Install plugin via `/plugin` in the active tab", action: { onRunInActiveTab("/plugin") })
                : nil
        ) {
            ForEach(plugins) { plugin in
                SidebarListItem(title: plugin.name, detail: plugin.scope)
            }
            if plugins.isEmpty {
                EmptyStateView(
                    icon: "puzzlepiece.extension",
                    message: ScopeCopy.empty("plugins", environment: environment),
                    cta: hasActiveSession ? .init(label: "Run /plugin in active tab", action: { onRunInActiveTab("/plugin") }) : nil
                )
            }
        }
    }
}

// MARK: - Permissions

struct PermissionsSection: View {
    let environment: ClaudeEnvironmentViewModel

    var body: some View {
        let rules = environment.permissionRules
        SidebarSection(title: "Permissions", count: rules.count) {
            ForEach(rules) { rule in
                SidebarListItem(
                    title: rule.rule,
                    detail: "\(rule.verb.rawValue) · \(SidebarFormat.label(rule.scope))",
                    accent: SidebarFormat.accent(for: rule.verb)
                )
            }
            if rules.isEmpty {
                EmptyStateView(icon: "lock.shield", message: ScopeCopy.empty("permission rules", environment: environment))
            }
        }
    }
}

// MARK: - Hooks

struct HooksSection: View {
    let environment: ClaudeEnvironmentViewModel

    var body: some View {
        let hooks = environment.hookBindings
        SidebarSection(title: "Hooks", count: environment.hookEventsCount) {
            ForEach(hooks) { binding in
                SidebarListItem(
                    title: binding.event,
                    detail: SidebarFormat.label(binding.scope) + " · " + SidebarFormat.shortHook(binding.command)
                )
            }
            if hooks.isEmpty {
                EmptyStateView(icon: "bolt.horizontal", message: ScopeCopy.empty("hooks", environment: environment))
            }
        }
    }
}

// MARK: - Copy & formatting

/// Empty-state text that says why a list is empty under the current scope.
private enum ScopeCopy {
    static func empty(_ noun: String, environment: ClaudeEnvironmentViewModel) -> String {
        if environment.currentDirectory == nil { return "No \(noun) configured." }
        return environment.scope == .project
            ? "No \(noun) specific to this project."
            : "No \(noun) configured."
    }
}

enum SidebarFormat {
    static func label(_ scope: EffectiveClaudeSettings.Scope) -> String {
        switch scope {
        case .global: return "global"
        case .project: return "project"
        case .local: return "local"
        }
    }

    static func accent(for scope: EffectiveClaudeSettings.Scope) -> Color {
        switch scope {
        case .global: return AppTheme.Colors.statusBlue
        case .project: return AppTheme.Colors.statusGreen
        case .local: return AppTheme.Colors.statusAmber
        }
    }

    static func accent(for verb: EffectiveClaudeSettings.PermissionRule.Verb) -> Color {
        switch verb {
        case .allow: return AppTheme.Colors.statusGreen
        case .ask: return AppTheme.Colors.statusAmber
        case .deny: return AppTheme.Colors.statusRed
        }
    }

    static func mcpDetail(_ server: EffectiveClaudeSettings.McpBinding) -> String {
        let command = shortCommand(server.command)
        return command.isEmpty ? label(server.scope) : "\(label(server.scope)) · \(command)"
    }

    /// The binary name is enough to identify a server in a narrow panel.
    static func shortCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return (first as NSString).lastPathComponent
    }

    static func shortHook(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return firstLine.count > 30 ? String(firstLine.prefix(27)) + "…" : firstLine
    }
}
