//
//  EffectiveClaudeSettings.swift
//  Xylem
//
//  Merges global + project shared + project local settings into the
//  effective view the sidebar should display. Follows Claude Code's merge
//  rules: later layers override scalar fields, collections are unioned.
//

import Foundation

nonisolated struct EffectiveClaudeSettings {
    struct HookBinding: Identifiable, Hashable {
        var id: String { event + "|" + command + "|" + scope.rawValue }
        let event: String
        let command: String
        let scope: Scope
    }

    struct McpBinding: Identifiable, Hashable {
        var id: String { name + "|" + scope.rawValue }
        let name: String
        let command: String
        let scope: Scope
    }

    struct PermissionRule: Identifiable, Hashable {
        var id: String { rule + "|" + verb.rawValue + "|" + scope.rawValue }
        let rule: String
        let verb: Verb
        let scope: Scope

        enum Verb: String { case allow, ask, deny }
    }

    enum Scope: String, Hashable { case global, project, local }

    let enabledPluginIDs: Set<String>
    /// Plugins switched on by the project's own settings layers (shared or
    /// local), as opposed to inherited from the global layer.
    let projectEnabledPluginIDs: Set<String>
    let hookBindings: [HookBinding]
    let mcpBindings: [McpBinding]
    let permissionRules: [PermissionRule]
    let statusLineCommand: String?
    /// The model a fresh session starts on: local > project > global.
    let defaultModel: String?
    let scopeLabel: String

    static func merge(
        global: ClaudeSettings?,
        projectShared: ClaudeSettings?,
        projectLocal: ClaudeSettings?,
        projectLabel: String?,
        additionalMcpBindings: [McpBinding] = []
    ) -> EffectiveClaudeSettings {
        var enabledPlugins = Set<String>()
        (global?.enabledPlugins ?? [:]).forEach { if $0.value { enabledPlugins.insert($0.key) } }
        (projectShared?.enabledPlugins ?? [:]).forEach {
            if $0.value { enabledPlugins.insert($0.key) } else { enabledPlugins.remove($0.key) }
        }
        (projectLocal?.enabledPlugins ?? [:]).forEach {
            if $0.value { enabledPlugins.insert($0.key) } else { enabledPlugins.remove($0.key) }
        }

        var projectEnabled = Set<String>()
        for layer in [projectShared, projectLocal] {
            (layer?.enabledPlugins ?? [:]).forEach {
                if $0.value { projectEnabled.insert($0.key) } else { projectEnabled.remove($0.key) }
            }
        }
        projectEnabled.formIntersection(enabledPlugins)

        var hooks: [HookBinding] = []
        hooks.append(contentsOf: bindings(from: global?.hooks, scope: .global))
        hooks.append(contentsOf: bindings(from: projectShared?.hooks, scope: .project))
        hooks.append(contentsOf: bindings(from: projectLocal?.hooks, scope: .local))

        var mcps: [McpBinding] = []
        mcps.append(contentsOf: mcpBindings(from: global?.mcpServers, scope: .global))
        mcps.append(contentsOf: mcpBindings(from: projectShared?.mcpServers, scope: .project))
        mcps.append(contentsOf: mcpBindings(from: projectLocal?.mcpServers, scope: .local))
        mcps.append(contentsOf: additionalMcpBindings)
        // The same server can be declared in settings.json and ~/.claude.json
        // under one scope; keep the first so ids stay unique for ForEach.
        var seenMcp = Set<String>()
        mcps = mcps.filter { seenMcp.insert($0.id).inserted }

        var rules: [PermissionRule] = []
        rules.append(contentsOf: permissionRules(from: global?.permissions, scope: .global))
        rules.append(contentsOf: permissionRules(from: projectShared?.permissions, scope: .project))
        rules.append(contentsOf: permissionRules(from: projectLocal?.permissions, scope: .local))

        // Identical hooks / rules in one layer would share an id and break
        // ForEach; keep the first of each.
        var seenHooks = Set<String>()
        hooks = hooks.filter { seenHooks.insert($0.id).inserted }
        var seenRules = Set<String>()
        rules = rules.filter { seenRules.insert($0.id).inserted }

        let statusLine = projectLocal?.statusLine?.command
            ?? projectShared?.statusLine?.command
            ?? global?.statusLine?.command

        let scopeLabel = projectLabel.map { "Project: \($0)" } ?? "Global"

        return EffectiveClaudeSettings(
            enabledPluginIDs: enabledPlugins,
            projectEnabledPluginIDs: projectEnabled,
            hookBindings: hooks,
            mcpBindings: mcps,
            permissionRules: rules,
            statusLineCommand: statusLine,
            defaultModel: projectLocal?.model ?? projectShared?.model ?? global?.model,
            scopeLabel: scopeLabel
        )
    }

    private static func bindings(
        from hooks: [String: [ClaudeSettings.HookGroup]]?,
        scope: Scope
    ) -> [HookBinding] {
        guard let hooks else { return [] }
        var result: [HookBinding] = []
        for (event, groups) in hooks {
            for group in groups {
                for entry in group.hooks ?? [] {
                    result.append(HookBinding(event: event, command: entry.summary, scope: scope))
                }
            }
        }
        return result
    }

    private static func mcpBindings(
        from servers: [String: ClaudeSettings.McpServer]?,
        scope: Scope
    ) -> [McpBinding] {
        guard let servers else { return [] }
        return servers.map { key, value in
            let command = [value.command, (value.args ?? []).joined(separator: " ")]
                .compactMap { $0 }
                .joined(separator: " ")
            return McpBinding(name: key, command: command, scope: scope)
        }
    }

    private static func permissionRules(
        from permissions: ClaudeSettings.Permissions?,
        scope: Scope
    ) -> [PermissionRule] {
        guard let permissions else { return [] }
        let allow = (permissions.allow ?? []).map { PermissionRule(rule: $0, verb: .allow, scope: scope) }
        let ask = (permissions.ask ?? []).map { PermissionRule(rule: $0, verb: .ask, scope: scope) }
        let deny = (permissions.deny ?? []).map { PermissionRule(rule: $0, verb: .deny, scope: scope) }
        return allow + ask + deny
    }
}
