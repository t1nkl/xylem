//
//  ProjectScopeFilter.swift
//  Xylem
//
//  Decides what the right panel shows for the active project. The loader
//  produces the full effective environment (global + project + plugins);
//  this pure filter narrows it to what belongs to the project itself when
//  the panel is in "This project" mode:
//
//    · plugins      installed for this directory (project/local install)
//                   or switched on by the project's own settings layers
//    · skills/agents from `<project>/.claude/…`, or shipped by such a plugin
//    · MCP, permissions, hooks: everything except the global layer
//
//  "All" (or no project open) shows the full effective set, as before.
//  Directories are not filtered; that list is always global.
//
//  Grouping (plugin skill groups, agent teams) happens here too, once per
//  change, so section views never sort or group inside `body`.
//

import Foundation

/// What the right panel lists. Persisted per user (UserDefaults).
nonisolated enum SidebarScope: String, CaseIterable, Sendable {
    case project, all

    var title: String {
        switch self {
        case .project: return "This project"
        case .all: return "All"
        }
    }
}

/// Everything the environment loader read for one directory, unfiltered.
nonisolated struct ClaudeEnvironmentSnapshot: Equatable, Sendable {
    var projectDirectory: String?
    var scopeLabel: String = "Global"
    var defaultModel: String?
    var enabledPlugins: [InstalledPlugin] = []
    var projectEnabledPluginIDs: Set<String> = []
    var skills: [InstalledSkill] = []
    var agents: [InstalledAgent] = []
    var mcpServers: [EffectiveClaudeSettings.McpBinding] = []
    var permissionRules: [EffectiveClaudeSettings.PermissionRule] = []
    var hookBindings: [EffectiveClaudeSettings.HookBinding] = []
}

/// A named sub-group inside a section (a plugin's skills, an agent team).
nonisolated struct SidebarGroup<Item: Identifiable & Hashable & Sendable>: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let members: [Item]
}

/// A section's rows: ungrouped items first, then collapsible groups.
nonisolated struct GroupedItems<Item: Identifiable & Hashable & Sendable>: Hashable, Sendable {
    var flat: [Item] = []
    var groups: [SidebarGroup<Item>] = []

    var count: Int { flat.count + groups.reduce(0) { $0 + $1.members.count } }
    var isEmpty: Bool { flat.isEmpty && groups.isEmpty }

    /// Splits `items` by `groupKey` (nil / empty → flat). Groups are sorted
    /// by name; item order inside a group is preserved.
    init(_ items: [Item], groupKey: (Item) -> String?) {
        var grouped: [String: [Item]] = [:]
        for item in items {
            if let key = groupKey(item), !key.isEmpty {
                grouped[key, default: []].append(item)
            } else {
                flat.append(item)
            }
        }
        groups = grouped.keys.sorted().map { SidebarGroup(name: $0, members: grouped[$0]!) }
    }

    init() {}
}

/// The filtered, grouped lists the right panel renders.
nonisolated struct VisibleEnvironment: Equatable, Sendable {
    var plugins: [InstalledPlugin] = []
    var skills = GroupedItems<InstalledSkill>()
    var agents = GroupedItems<InstalledAgent>()
    var mcpServers: [EffectiveClaudeSettings.McpBinding] = []
    var permissionRules: [EffectiveClaudeSettings.PermissionRule] = []
    var hookBindings: [EffectiveClaudeSettings.HookBinding] = []

    var hookEventsCount: Int { Set(hookBindings.map(\.event)).count }
}

nonisolated enum ProjectScopeFilter {
    static func visible(_ snapshot: ClaudeEnvironmentSnapshot, scope: SidebarScope) -> VisibleEnvironment {
        guard scope == .project, let directory = snapshot.projectDirectory else {
            return grouped(
                plugins: snapshot.enabledPlugins,
                skills: snapshot.skills,
                agents: snapshot.agents,
                mcp: snapshot.mcpServers,
                permissions: snapshot.permissionRules,
                hooks: snapshot.hookBindings
            )
        }

        let projectPlugins = snapshot.enabledPlugins.filter {
            $0.isInstalled(forProject: directory) || snapshot.projectEnabledPluginIDs.contains($0.id)
        }
        let projectPluginIDs = Set(projectPlugins.map(\.id))

        return grouped(
            plugins: projectPlugins,
            skills: snapshot.skills.filter {
                $0.scope == .project || ($0.scope == .plugin && $0.pluginID.map(projectPluginIDs.contains) == true)
            },
            agents: snapshot.agents.filter {
                $0.scope == .project || ($0.scope == .plugin && $0.pluginID.map(projectPluginIDs.contains) == true)
            },
            mcp: snapshot.mcpServers.filter { $0.scope != .global },
            permissions: snapshot.permissionRules.filter { $0.scope != .global },
            hooks: snapshot.hookBindings.filter { $0.scope != .global }
        )
    }

    private static func grouped(
        plugins: [InstalledPlugin],
        skills: [InstalledSkill],
        agents: [InstalledAgent],
        mcp: [EffectiveClaudeSettings.McpBinding],
        permissions: [EffectiveClaudeSettings.PermissionRule],
        hooks: [EffectiveClaudeSettings.HookBinding]
    ) -> VisibleEnvironment {
        VisibleEnvironment(
            plugins: plugins,
            // User and project skills stay flat; plugin skills group per plugin.
            skills: GroupedItems(skills) { $0.scope == .plugin ? $0.pluginName : nil },
            // Agents group by team (frontmatter `team:` or their plugin).
            agents: GroupedItems(agents) { $0.team },
            mcpServers: mcp,
            permissionRules: permissions,
            hookBindings: hooks
        )
    }
}
