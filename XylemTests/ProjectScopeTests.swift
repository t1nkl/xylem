//
//  ProjectScopeTests.swift
//  XylemTests
//
//  What the right panel shows for "This project" vs "All", where MCP servers
//  come from, project-scoped session listing, and which model the header
//  shows after a pick.
//

import Testing
import Foundation

struct ProjectScopeFilterTests {

    private let project = "/Users/dev/Sites/app"

    private func plugin(_ name: String, installs: [InstalledPlugin.Install]) -> InstalledPlugin {
        InstalledPlugin(id: "\(name)@m", name: name, marketplace: "m", version: "1",
                        scope: installs.first?.scope ?? "user", projectPath: installs.first?.projectPath,
                        installPath: nil, installs: installs)
    }

    private func skill(_ name: String, scope: InstalledSkill.Scope, plugin: String? = nil) -> InstalledSkill {
        InstalledSkill(name: name, pluginID: plugin.map { "\($0)@m" }, pluginName: plugin, pluginVersion: nil, scope: scope)
    }

    private var snapshot: ClaudeEnvironmentSnapshot {
        let user = plugin("everywhere", installs: [.init(scope: "user", projectPath: nil)])
        let local = plugin("only-here", installs: [
            .init(scope: "user", projectPath: nil),
            .init(scope: "local", projectPath: project)
        ])
        let elsewhere = plugin("other-project", installs: [.init(scope: "local", projectPath: "/Users/dev/other")])
        let enabledByProjectSettings = plugin("team-plugin", installs: [.init(scope: "user", projectPath: nil)])
        return ClaudeEnvironmentSnapshot(
            projectDirectory: project,
            scopeLabel: "Project: app",
            enabledPlugins: [user, local, elsewhere, enabledByProjectSettings],
            projectEnabledPluginIDs: ["team-plugin@m"],
            skills: [
                skill("global-skill", scope: .user),
                skill("repo-skill", scope: .project),
                skill("from-everywhere", scope: .plugin, plugin: "everywhere"),
                skill("from-only-here", scope: .plugin, plugin: "only-here")
            ],
            mcpServers: [
                .init(name: "obsidian", command: "obsidian", scope: .global),
                .init(name: "postman", command: "postman", scope: .local),
                .init(name: "db", command: "db", scope: .project)
            ],
            permissionRules: [
                .init(rule: "Bash(ls)", verb: .allow, scope: .global),
                .init(rule: "Bash(rm)", verb: .deny, scope: .project)
            ],
            hookBindings: [
                .init(event: "Stop", command: "notify", scope: .global),
                .init(event: "PreToolUse", command: "lint", scope: .local)
            ]
        )
    }

    @Test func projectScopeKeepsOnlyWhatBelongsToTheProject() {
        let visible = ProjectScopeFilter.visible(snapshot, scope: .project)
        #expect(visible.plugins.map(\.name) == ["only-here", "team-plugin"])
        #expect(visible.skills.flat.map(\.name) == ["repo-skill"])
        #expect(visible.skills.groups.map(\.name) == ["only-here"])
        #expect(visible.mcpServers.map(\.name) == ["postman", "db"])
        #expect(visible.permissionRules.map(\.rule) == ["Bash(rm)"])
        #expect(visible.hookBindings.map(\.event) == ["PreToolUse"])
    }

    @Test func allScopeShowsEverything() {
        let visible = ProjectScopeFilter.visible(snapshot, scope: .all)
        #expect(visible.plugins.count == 4)
        #expect(visible.skills.count == 4)
        #expect(visible.mcpServers.count == 3)
        #expect(visible.hookEventsCount == 2)
    }

    @Test func withoutAProjectProjectScopeFallsBackToAll() {
        var global = snapshot
        global.projectDirectory = nil
        #expect(ProjectScopeFilter.visible(global, scope: .project) == ProjectScopeFilter.visible(global, scope: .all))
    }
}

struct ClaudeMcpConfigReaderTests {

    @Test func readsUserLocalAndProjectServers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-mcp-\(UUID().uuidString)")
        let project = root.appending(path: "app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let userConfig = root.appending(path: "claude.json")
        try Data(#"""
        {"mcpServers":{"obsidian":{"command":"uvx","args":["obsidian-mcp"]},"phpstorm":{"type":"sse","url":"http://localhost:64342/sse"}},
         "projects":{"\#(project.path)":{"mcpServers":{"postman":{"command":"npx"}}},"/elsewhere":{"mcpServers":{"nope":{"command":"x"}}}},
         "numStartups": 12}
        """#.utf8).write(to: userConfig)
        try Data(#"{"mcpServers":{"db":{"command":"pg-mcp"}}}"#.utf8).write(to: project.appending(path: ".mcp.json"))

        let bindings = ClaudeMcpConfigReader(userConfigURL: userConfig).mcpBindings(projectDirectory: project.path)
        let byName = Dictionary(uniqueKeysWithValues: bindings.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["obsidian", "phpstorm", "postman", "db"])
        #expect(byName["obsidian"]?.scope == .global)
        #expect(byName["obsidian"]?.command == "uvx obsidian-mcp")
        #expect(byName["phpstorm"]?.command == "http://localhost:64342/sse")
        #expect(byName["postman"]?.scope == .local)
        #expect(byName["db"]?.scope == .project)
    }

    @Test func duplicateServerAcrossSourcesIsListedOnce() {
        let effective = EffectiveClaudeSettings.merge(
            global: try? JSONDecoder().decode(ClaudeSettings.self, from: Data(#"{"mcpServers":{"obsidian":{"command":"a"}}}"#.utf8)),
            projectShared: nil,
            projectLocal: nil,
            projectLabel: nil,
            additionalMcpBindings: [.init(name: "obsidian", command: "b", scope: .global)]
        )
        #expect(effective.mcpBindings.map(\.name) == ["obsidian"])
    }
}

struct ProjectSessionListingTests {

    @Test func listsSessionsOfTheProjectAndItsSubdirectoriesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func session(cwd: String, prompt: String) throws {
            let folder = root.appending(path: SessionFileLocator.encodedFolderName(for: cwd))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let line = #"{"type":"user","cwd":"\#(cwd)","message":{"content":"\#(prompt)"}}"#
            try Data((line + "\n").utf8).write(to: folder.appending(path: "\(UUID().uuidString).jsonl"))
        }
        try session(cwd: "/srv/app", prompt: "root prompt")
        try session(cwd: "/srv/app/backend", prompt: "sub prompt")
        try session(cwd: "/srv/app-other", prompt: "sibling prompt")   // same encoded prefix, different project

        let reader = ClaudeSessionReader(projectsDirectory: root)
        let titles = Set(reader.loadSessions(projectDirectory: "/srv/app", limit: 50).map(\.title))
        #expect(titles == ["root prompt", "sub prompt"])
        #expect(reader.loadSessions(limit: 50).count == 3)
    }

    /// Throwaway `claude -p` runs in temp folders (seen: hundreds of
    /// `/private/var/folders/.../cwd/<random>`) stay out of Directories,
    /// Recent Projects and the global Sessions list.
    @Test func temporaryFolderRunsAreHiddenFromProjectsAndSessions() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func session(cwd: String, prompt: String) throws {
            let folder = root.appending(path: SessionFileLocator.encodedFolderName(for: cwd))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let line = #"{"type":"user","cwd":"\#(cwd)","message":{"content":"\#(prompt)"}}"#
            try Data((line + "\n").utf8).write(to: folder.appending(path: "\(UUID().uuidString).jsonl"))
        }
        try session(cwd: "/Users/x/Code/app", prompt: "real")
        try session(cwd: "/private/var/folders/0l/abc/T/summarizer/cwd/tyx8id34", prompt: "temp 1")
        try session(cwd: "/var/folders/0l/abc/T/run/4o16ia52", prompt: "temp 2")
        try session(cwd: "/private/tmp/scratch", prompt: "temp 3")
        try session(cwd: "/tmp/scratch2", prompt: "temp 4")
        try session(cwd: "/tmp-tools/app", prompt: "not temp")   // encodes like /tmp/... but isn't

        let projects = try ClaudeProjectRepository(projectsDirectory: root).loadProjects()
        #expect(Set(projects.map(\.path)) == ["/Users/x/Code/app", "/tmp-tools/app"])

        let reader = ClaudeSessionReader(projectsDirectory: root)
        #expect(Set(reader.loadSessions(limit: 50).map(\.title)) == ["real", "not temp"])
        // A tab opened in a temp folder still lists that folder's sessions.
        #expect(reader.loadSessions(projectDirectory: "/private/tmp/scratch", limit: 50).map(\.title) == ["temp 3"])
    }
}

struct ModelSwitchDisplayTests {

    private func stats(id: String, prompt: Date?, reply: Date?) -> StatsSnapshot {
        var s = StatsSnapshot()
        s.model = ModelNameFormatter.display(id)
        s.modelID = id
        s.lastPromptAt = prompt
        s.lastAssistantAt = reply
        return s
    }

    @Test func pickHoldsThroughTheRunningTurnAndEndsWithTheNextReply() throws {
        let opus = try #require(ClaudeModelChoice.all.first { $0.alias == "opus" })
        let haiku = try #require(ClaudeModelChoice.all.first { $0.alias == "haiku" })
        let t = Date(timeIntervalSince1970: 1_000)
        let pick = ModelSwitchController.Pick(choice: haiku, at: t)

        // Picked mid-turn: the agent keeps replying on the old model (the
        // `/model` is queued); no new prompt yet, so the pick stays.
        let midTurn = stats(id: "claude-opus-5-5", prompt: t.addingTimeInterval(-60), reply: t.addingTimeInterval(30))
        #expect(ModelSwitchController.displayedModel(pick: pick, stats: midTurn).choice == haiku)

        // New prompt sent, reply not here yet: still the pick.
        let waiting = stats(id: "claude-opus-5-5", prompt: t.addingTimeInterval(60), reply: t.addingTimeInterval(30))
        #expect(ModelSwitchController.displayedModel(pick: pick, stats: waiting).choice == haiku)

        // Reply to that prompt: the transcript is authoritative, whatever it says
        // (here a later manual `/model opus` in the terminal).
        let answered = stats(id: "claude-opus-5-5", prompt: t.addingTimeInterval(60), reply: t.addingTimeInterval(90))
        let shown = ModelSwitchController.displayedModel(pick: pick, stats: answered)
        #expect(shown.title == "Opus")   // family only, no version in the selector
        #expect(shown.choice == opus)
    }

    @Test func freshSessionShowsTheSettingsDefaultModel() throws {
        let decode = { (json: String) in try JSONDecoder().decode(ClaudeSettings.self, from: Data(json.utf8)) }
        let effective = EffectiveClaudeSettings.merge(
            global: try decode(#"{"model":"opus[1m]"}"#),
            projectShared: try decode(#"{"model":"sonnet"}"#),
            projectLocal: nil,
            projectLabel: "app"
        )
        #expect(effective.defaultModel == "sonnet")   // project beats global
        #expect(ModelSwitchController.defaultModelDisplay("opus[1m]").title == "Opus")
        #expect(ModelSwitchController.defaultModelDisplay(nil).title == nil)
    }

    @Test func choicesMatchFullModelIDs() {
        #expect(ClaudeModelChoice.matching(modelID: "claude-fable-5-2")?.alias == "fable")
        #expect(ClaudeModelChoice.matching(modelID: "claude-sonnet-5-5[1m]")?.alias == "sonnet")
        #expect(ClaudeModelChoice.matching(modelID: "<synthetic>") == nil)
        #expect(ClaudeModelChoice.all.map(\.command) == ["/model fable", "/model opus", "/model sonnet", "/model haiku"])
        #expect(ClaudeModelChoice.all.map(\.title) == ["Fable", "Opus", "Sonnet", "Haiku"])
    }
}

struct UserScopedRegistryTests {

    @Test func userSkillsAndAgentsAreListed() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "xylem-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "skills/my-skill"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: "agents"), withIntermediateDirectories: true)
        try Data("---\nname: reviewer\ndescription: Reviews code\n---\nbody".utf8)
            .write(to: home.appending(path: "agents/reviewer.md"))

        let skills = SkillsRegistry(userClaudeDirectory: home).loadSkills(projectDirectory: nil, plugins: [])
        let agents = AgentsRegistry(userClaudeDirectory: home).loadAgents(projectDirectory: nil, plugins: [])
        #expect(skills.map(\.name) == ["my-skill"] && skills.first?.scope == .user)
        #expect(agents.map(\.name) == ["reviewer"] && agents.first?.description == "Reviews code")
    }
}

struct ModelPickAgainstTranscriptTests {

    /// Folds a real line sequence through SessionStatsReader: tool-loop
    /// replies after the pick keep it; a reply to a new prompt ends it.
    @Test func realTranscriptSequence() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "xylem-pick-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func assistant(_ id: String, _ model: String, _ time: String) -> String {
            #"{"type":"assistant","timestamp":"2026-11-13T\#(time).000Z","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":1,"output_tokens":1}}}"#
        }
        func user(_ time: String) -> String {
            #"{"type":"user","timestamp":"2026-11-13T\#(time).000Z","message":{"content":"next prompt"}}"#
        }
        func toolResult(_ time: String) -> String {
            #"{"type":"user","timestamp":"2026-11-13T\#(time).000Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        }
        func append(_ lines: [String]) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try handle.close()
        }
        let haiku = try #require(ClaudeModelChoice.all.first { $0.alias == "haiku" })
        let pick = ModelSwitchController.Pick(choice: haiku, at: try #require(TimestampParser.parse("2026-11-13T10:00:10.000Z")))

        try Data((user("10:00:00") + "\n" + assistant("a", "claude-opus-5-5", "10:00:05") + "\n").utf8).write(to: url)
        // Still in the same agentic turn: tool result + another opus reply.
        try append([toolResult("10:00:20"), assistant("b", "claude-opus-5-5", "10:00:25")])
        let midTurn = try #require(SessionStatsReader().readStats(from: url))
        #expect(ModelSwitchController.displayedModel(pick: pick, stats: midTurn).choice == haiku)

        // Next human prompt and its reply on the new model.
        try append([user("10:01:00"), assistant("c", "claude-haiku-5-5", "10:01:05")])
        let answered = try #require(SessionStatsReader().readStats(from: url))
        #expect(answered.modelID == "claude-haiku-5-5")
        #expect(ModelSwitchController.displayedModel(pick: pick, stats: answered).title == "Haiku")
    }
}

struct SessionFirstPromptTests {

    /// The Sessions row tooltip shows the whole first prompt; the title is
    /// still the 60-character cut.
    @Test func sessionKeepsTheWholeFirstPromptForTheTooltip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xylem-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/srv/long"
        let folder = root.appending(path: SessionFileLocator.encodedFolderName(for: cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prompt = String(repeating: "word ", count: 40) + "end"
        let line = #"{"type":"user","cwd":"\#(cwd)","message":{"content":"\#(prompt)"}}"#
        try Data((line + "\n").utf8).write(to: folder.appending(path: "\(UUID().uuidString).jsonl"))

        let session = try #require(ClaudeSessionReader(projectsDirectory: root).loadSessions(limit: 5).first)
        #expect(session.firstPrompt == prompt)
        #expect(session.title.count == 61)            // 60 + "…"
        #expect(session.title.hasSuffix("…"))
    }
}

@MainActor
struct OnboardingResumeLabelTests {

    private func session(path: String, title: String) -> ClaudeSession {
        ClaudeSession(id: "s", projectID: "p", projectPath: path, title: title,
                      lastModified: .distantPast, fileURL: URL(fileURLWithPath: "/x.jsonl"))
    }

    /// The Resume button names the project, never the user's prompt (which
    /// may be in another language than the UI).
    @Test func resumeButtonNamesTheProjectNotThePrompt() {
        #expect(OnboardingSheet.resumeLabel(for: session(path: "/Users/me/Code/sample-api", title: "перевір тести")) == "sample-api")
        #expect(OnboardingSheet.resumeLabel(for: session(path: "/", title: "x")) == "last session")
        #expect(OnboardingSheet.resumeLabel(for: session(path: "/srv/" + String(repeating: "a", count: 30), title: "x")).count == 23)
    }
}
