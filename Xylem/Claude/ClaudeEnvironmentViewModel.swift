//
//  ClaudeEnvironmentViewModel.swift
//  Xylem
//
//  Resolves the Claude environment for the active project and exposes what
//  the right panel should list for the chosen `SidebarScope`.
//
//  Pipeline: `ClaudeEnvironmentLoader` reads every source once, off the
//  main actor → `ClaudeEnvironmentSnapshot` (unfiltered) → the pure
//  `ProjectScopeFilter` → one stored property per section. Each section
//  view reads only its own property, so a change in, say, MCP servers
//  re-renders the MCP section and nothing else. Every write is
//  equality-guarded: file-watcher reloads usually reproduce identical data.
//

import Foundation
import Observation

@Observable
final class ClaudeEnvironmentViewModel {
    // MARK: Section data (filtered for `scope`)

    private(set) var plugins: [InstalledPlugin] = []
    private(set) var skills = GroupedItems<InstalledSkill>()
    private(set) var agents = GroupedItems<InstalledAgent>()
    private(set) var mcpServers: [EffectiveClaudeSettings.McpBinding] = []
    private(set) var permissionRules: [EffectiveClaudeSettings.PermissionRule] = []
    private(set) var hookBindings: [EffectiveClaudeSettings.HookBinding] = []
    private(set) var hookEventsCount = 0

    // MARK: Context

    private(set) var scopeLabel: String = "Global"
    /// Model a new session in this directory starts on (settings `model`).
    private(set) var defaultModel: String?
    private(set) var currentDirectory: String?
    private(set) var isLoading = false

    /// "This project" vs "All". Persisted; switching re-filters the snapshot
    /// already in memory, no disk work.
    var scope: SidebarScope {
        didSet {
            guard scope != oldValue else { return }
            UserDefaults.standard.set(scope.rawValue, forKey: Self.scopeKey)
            publish()
        }
    }

    // MARK: Private

    @ObservationIgnored private var snapshot = ClaudeEnvironmentSnapshot()
    @ObservationIgnored private let loader: ClaudeEnvironmentLoader
    @ObservationIgnored private let watcher = FileSystemWatcher()
    /// The most recently dispatched reload, so a burst of file-system events
    /// can't pile up concurrent loads racing to apply.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    private static let scopeKey = "sidebarScope"

    init(loader: ClaudeEnvironmentLoader = ClaudeEnvironmentLoader()) {
        self.loader = loader
        self.scope = UserDefaults.standard.string(forKey: Self.scopeKey)
            .flatMap(SidebarScope.init(rawValue:)) ?? .project
        watcher.setHandler { [weak self] in
            let target = self
            Task { @MainActor in
                guard let target else { return }
                target.reload(projectDirectory: target.currentDirectory)
            }
        }
    }

    func reload(projectDirectory: String? = nil) {
        reloadTask?.cancel()
        if currentDirectory != projectDirectory { currentDirectory = projectDirectory }
        if !isLoading { isLoading = true }
        let loader = UncheckedSendable(loader)
        reloadTask = Task { [weak self] in
            let fresh = await Self.load(projectDirectory: projectDirectory, loader: loader)
            guard !Task.isCancelled, let self else { return }
            if self.snapshot != fresh {
                self.snapshot = fresh
                self.publish()
            }
            self.watcher.watch(paths: ClaudeEnvironmentLoader.watchPaths(for: projectDirectory))
            if self.isLoading { self.isLoading = false }
        }
    }

    @concurrent nonisolated
    private static func load(
        projectDirectory: String?,
        loader: UncheckedSendable<ClaudeEnvironmentLoader>
    ) async -> ClaudeEnvironmentSnapshot {
        loader.value.load(projectDirectory: projectDirectory)
    }

    /// Re-filters the in-memory snapshot and writes only what changed.
    private func publish() {
        let visible = ProjectScopeFilter.visible(snapshot, scope: scope)
        if scopeLabel != snapshot.scopeLabel { scopeLabel = snapshot.scopeLabel }
        if defaultModel != snapshot.defaultModel { defaultModel = snapshot.defaultModel }
        if plugins != visible.plugins { plugins = visible.plugins }
        if skills != visible.skills { skills = visible.skills }
        if agents != visible.agents { agents = visible.agents }
        if mcpServers != visible.mcpServers { mcpServers = visible.mcpServers }
        if permissionRules != visible.permissionRules { permissionRules = visible.permissionRules }
        if hookBindings != visible.hookBindings { hookBindings = visible.hookBindings }
        if hookEventsCount != visible.hookEventsCount { hookEventsCount = visible.hookEventsCount }
    }
}

/// Reads every source the right panel needs for one directory. Stateless
/// and `nonisolated`; runs off the main actor. Sources are injected so
/// previews and tests can use fixtures.
nonisolated struct ClaudeEnvironmentLoader {
    let settingsReader: ClaudeSettingsReading
    let pluginsReader: InstalledPluginsReading
    let skillsReader: SkillsReading
    let agentsReader: AgentsReading
    let mcpReader: ClaudeMcpConfigReading

    init(
        settingsReader: ClaudeSettingsReading = ClaudeSettingsReader(),
        pluginsReader: InstalledPluginsReading = InstalledPluginsRegistry(),
        skillsReader: SkillsReading = SkillsRegistry(),
        agentsReader: AgentsReading = AgentsRegistry(),
        mcpReader: ClaudeMcpConfigReading = ClaudeMcpConfigReader()
    ) {
        self.settingsReader = settingsReader
        self.pluginsReader = pluginsReader
        self.skillsReader = skillsReader
        self.agentsReader = agentsReader
        self.mcpReader = mcpReader
    }

    func load(projectDirectory: String?) -> ClaudeEnvironmentSnapshot {
        let global = settingsReader.readGlobalSettings()
        let (shared, local) = projectDirectory
            .map { settingsReader.readProjectSettings(at: $0) }
            ?? (nil, nil)
        let effective = EffectiveClaudeSettings.merge(
            global: global,
            projectShared: shared,
            projectLocal: local,
            projectLabel: projectDirectory.map { ($0 as NSString).lastPathComponent },
            additionalMcpBindings: mcpReader.mcpBindings(projectDirectory: projectDirectory)
        )
        // installed_plugins.json is read once and handed to the skill and
        // agent registries.
        let enabled = pluginsReader.loadInstalledPlugins()
            .filter { effective.enabledPluginIDs.contains($0.id) }

        return ClaudeEnvironmentSnapshot(
            projectDirectory: projectDirectory,
            scopeLabel: effective.scopeLabel,
            defaultModel: effective.defaultModel,
            enabledPlugins: enabled,
            projectEnabledPluginIDs: effective.projectEnabledPluginIDs,
            skills: skillsReader.loadSkills(projectDirectory: projectDirectory, plugins: enabled),
            agents: agentsReader.loadAgents(projectDirectory: projectDirectory, plugins: enabled),
            mcpServers: effective.mcpBindings,
            permissionRules: effective.permissionRules,
            hookBindings: effective.hookBindings
        )
    }

    /// Files whose change should trigger a reload. `~/.claude.json` is left
    /// out on purpose: Claude Code rewrites it on every session.
    /// `installed_plugins.json` is watched instead of the whole plugins
    /// directory, whose marketplace/cache churn fired constantly.
    static func watchPaths(for projectDirectory: String?) -> [String] {
        let config = ClaudeConfigDirectory.root.path
        var paths = [
            config + "/settings.json",
            config + "/plugins/installed_plugins.json",
            config + "/skills",
            config + "/agents"
        ]
        if let dir = projectDirectory {
            let claudeDir = dir + "/.claude"
            paths += [
                claudeDir,
                claudeDir + "/settings.json",
                claudeDir + "/settings.local.json",
                claudeDir + "/skills",
                claudeDir + "/agents",
                dir + "/.mcp.json"
            ]
        }
        let fm = FileManager.default
        return paths.filter { fm.fileExists(atPath: $0) }
    }
}
