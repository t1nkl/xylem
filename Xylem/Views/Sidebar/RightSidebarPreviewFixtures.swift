//
//  RightSidebarPreviewFixtures.swift
//  Xylem
//
//  Fixture-only readers for the right panel `#Preview`. Nothing here touches
//  the real `~/.claude` tree or spawns a shell: every reader returns canned
//  values sized like a typical project.
//

#if DEBUG
import SwiftUI

nonisolated enum RightSidebarPreviewFixtures {
    static let projectPath = "/Users/dev/Sites/app"

    static let sessionTitles = [
        "Refactor the billing webhook handler",
        "test",
        "how does the queue retry work in prod",
        "Reply with exactly the words I give you",
        "prepare the release notes for this week"
    ]

    /// Offsets in seconds: just now, just now, 41m, 3h, 6h, then older.
    static let sessionAges: [TimeInterval] = [5, 20, 41 * 60, 3 * 3600, 6 * 3600]

    static func sessions(count: Int = 50) -> [ClaudeSession] {
        (0..<count).map { index in
            let age = index < sessionAges.count ? sessionAges[index] : TimeInterval(index) * 3 * 3600
            let title = index < sessionTitles.count ? sessionTitles[index] : "Older session #\(index)"
            return ClaudeSession(
                id: "fixture-\(index)",
                projectID: "-Users-dev-Sites-app",
                projectPath: projectPath,
                title: title,
                lastModified: Date.now.addingTimeInterval(-age),
                fileURL: URL(fileURLWithPath: "/dev/null")
            )
        }
    }

    static let projects: [ClaudeProject] = [
        ClaudeProject(id: "a", path: "/Users/dev/Sites/app", displayName: "app", sessionCount: 42, lastModified: .now),
        ClaudeProject(id: "b", path: "/Users/dev/Sites/api", displayName: "api", sessionCount: 17, lastModified: .now)
    ]

    static let plugins: [InstalledPlugin] = (0..<19).map { index in
        InstalledPlugin(
            id: "plugin-\(index)@market",
            name: "plugin-\(index)",
            marketplace: "market",
            version: "1.0.\(index)",
            scope: "user",
            projectPath: nil,
            installPath: nil
        )
    }

    static let settings = ClaudeSettings(
        enabledPlugins: Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, true) }),
        mcpServers: [
            "context7": .init(command: "npx", args: ["-y", "@upstash/context7-mcp"]),
            "obsidian": .init(command: "uvx", args: ["mcp-obsidian"])
        ],
        hooks: Dictionary(uniqueKeysWithValues: (0..<25).map { index in
            ("Event\(index)", [ClaudeSettings.HookGroup(
                matcher: nil,
                hooks: [.init(type: "command", command: "~/.claude/hooks/hook-\(index).sh")]
            )])
        }),
        permissions: .init(
            allow: (0..<210).map { "Bash(tool-\($0):*)" },
            deny: (0..<8).map { "Read(secret-\($0))" }
        ),
        statusLine: nil
    )

    static let skills: [InstalledSkill] = (0..<19).map { index in
        InstalledSkill(name: "skill-\(index)", pluginID: nil, pluginName: nil, pluginVersion: nil, scope: .user)
    }

    static let agents: [InstalledAgent] = (0..<17).map { index in
        InstalledAgent(
            name: "agent-\(index)",
            description: nil,
            fileURL: URL(fileURLWithPath: "/dev/null"),
            pluginID: nil,
            pluginName: nil,
            pluginVersion: nil,
            scope: .user,
            team: nil
        )
    }

    static let teams: [AgentTeam] = [
        AgentTeam(
            name: "release-crew",
            createdAt: Date.now.addingTimeInterval(-3600),
            leadCwd: projectPath,
            members: [
                .init(name: "team-lead", agentType: "team-lead"),
                .init(name: "backend", agentType: "general-purpose"),
                .init(name: "reviewer", agentType: "php-code-reviewer")
            ]
        )
    ]

    static let gitStatus = GitStatus(
        branch: "feature/new-sidebar",
        isDirty: true,
        modified: 4,
        untracked: 2,
        ahead: 1,
        behind: 0,
        worktrees: [GitWorktree(path: projectPath, branch: "feature/new-sidebar", isCurrent: true)],
        branches: [
            GitBranch(name: "feature/new-sidebar", isCurrent: true, upstream: "origin/feature/new-sidebar"),
            GitBranch(name: "main", isCurrent: false, upstream: "origin/main")
        ],
        remotes: [GitRemote(name: "origin", url: "git@example.com:dev/app.git")],
        recentCommits: [
            GitCommit(id: "a1b2c3d", subject: "feat: restyle right panel", author: "dev", relativeDate: "2 hours ago"),
            GitCommit(id: "e4f5a6b", subject: "fix: tab dot colour", author: "dev", relativeDate: "1 day ago")
        ]
    )

    // MARK: - Stub readers

    nonisolated struct Sessions: ClaudeSessionReading {
        func loadSessions(limit: Int) -> [ClaudeSession] { RightSidebarPreviewFixtures.sessions(count: limit) }
        func loadSessions(projectDirectory: String, limit: Int) -> [ClaudeSession] {
            RightSidebarPreviewFixtures.sessions(count: min(limit, 12))
        }
    }

    nonisolated struct Projects: ClaudeProjectRepositoryProtocol {
        func loadProjects() throws -> [ClaudeProject] { RightSidebarPreviewFixtures.projects }
    }

    nonisolated struct Settings: ClaudeSettingsReading {
        func readGlobalSettings() -> ClaudeSettings? { RightSidebarPreviewFixtures.settings }
        func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?) {
            (nil, nil)
        }
    }

    nonisolated struct Plugins: InstalledPluginsReading {
        func loadInstalledPlugins() -> [InstalledPlugin] { RightSidebarPreviewFixtures.plugins }
    }

    nonisolated struct Skills: SkillsReading {
        func loadSkills(projectDirectory: String?, plugins: [InstalledPlugin]) -> [InstalledSkill] {
            RightSidebarPreviewFixtures.skills
        }
    }

    nonisolated struct Agents: AgentsReading {
        func loadAgents(projectDirectory: String?, plugins: [InstalledPlugin]) -> [InstalledAgent] {
            RightSidebarPreviewFixtures.agents
        }
    }

    nonisolated struct Mcp: ClaudeMcpConfigReading {
        func mcpBindings(projectDirectory: String?) -> [EffectiveClaudeSettings.McpBinding] { [] }
    }

    nonisolated struct GitRepo: GitRepositoryReading {
        func status(in directory: String) async -> GitStatus? { RightSidebarPreviewFixtures.gitStatus }
        func currentBranch(in directory: String) async -> String? { RightSidebarPreviewFixtures.gitStatus.branch }
    }

    nonisolated struct Teams: AgentTeamsReading {
        func loadTeams() -> [AgentTeam] { RightSidebarPreviewFixtures.teams }
    }

}

/// Owns fixture-backed view models so the preview renders without any
/// real session, terminal or file-system data.
struct RightSidebarPreviewHost: View {
    var tab: RightSidebarView.SidebarTab = .claude

    @State private var sessionList = SessionListViewModel(
        sessionReader: RightSidebarPreviewFixtures.Sessions(),
        projectRepository: RightSidebarPreviewFixtures.Projects()
    )
    @State private var environment = ClaudeEnvironmentViewModel(loader: ClaudeEnvironmentLoader(
        settingsReader: RightSidebarPreviewFixtures.Settings(),
        pluginsReader: RightSidebarPreviewFixtures.Plugins(),
        skillsReader: RightSidebarPreviewFixtures.Skills(),
        agentsReader: RightSidebarPreviewFixtures.Agents(),
        mcpReader: RightSidebarPreviewFixtures.Mcp()
    ))
    @State private var git = GitStatusViewModel(repository: RightSidebarPreviewFixtures.GitRepo())
    @State private var teams = AgentTeamsStore(reader: RightSidebarPreviewFixtures.Teams())

    var body: some View {
        RightSidebarView(
            sessionList: sessionList,
            environment: environment,
            gitStatus: git,
            agentTeams: teams,
            hasActiveSession: true,
            tab: tab
        )
        .frame(width: AppTheme.Metrics.inspectorIdealWidth, height: 760)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
        .task {
            environment.reload(projectDirectory: nil)
            sessionList.reload()
            teams.reload(projectDirectory: nil)
            await git.refresh(for: RightSidebarPreviewFixtures.projectPath)
        }
    }
}

#Preview("Right panel - Claude") {
    RightSidebarPreviewHost()
}

#Preview("Right panel - Git") {
    RightSidebarPreviewHost(tab: .git)
}
#endif
