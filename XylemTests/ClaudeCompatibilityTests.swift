//
//  ClaudeCompatibilityTests.swift
//  XylemTests
//
//  The app side of `make check-claude` (scripts/check-claude.py). The
//  script runs the installed Claude Code for real (a few cheap turns in a
//  temp folder, hooks captured) and saves what came out; this suite feeds
//  that output, and the user's own Claude config, through Xylem's actual
//  parsers - the same code the app runs - and writes one result per check
//  to `results-app.jsonl`. The script prints the report.
//
//  Runs only when XYLEM_CLAUDE_CHECK_DIR is set (xcodebuild passes
//  TEST_RUNNER_XYLEM_CLAUDE_CHECK_DIR through), so a normal test run skips
//  it. It never fails on a finding: findings go into the results file, and
//  a missing results file is what the script treats as a failure. Reads of
//  the real config are read-only and never print values, only counts and
//  key names.
//

import Testing
import Foundation

@MainActor
struct ClaudeCompatibilityTests {
    static let checkDirectory = ProcessInfo.processInfo.environment["XYLEM_CLAUDE_CHECK_DIR"]

    @Test(.enabled(if: checkDirectory != nil))
    func judgeCapturedClaudeOutput() throws {
        let dir = URL(fileURLWithPath: try #require(Self.checkDirectory))
        let manifestData = try Data(contentsOf: dir.appending(path: "manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        var judge = CompatibilityJudge(manifest: manifest, directory: dir)
        judge.run()
        try judge.write(to: dir.appending(path: "results-app.jsonl"))
    }
}

/// One finding: `status` is ok, warn, fail or skip.
private struct CheckResult {
    let id: String
    let status: String
    let feature: String
    let detail: String
}

private struct CompatibilityJudge {
    let manifest: [String: Any]
    let directory: URL
    var results: [CheckResult] = []

    init(manifest: [String: Any], directory: URL) {
        self.manifest = manifest
        self.directory = directory
    }

    mutating func run() {
        checkHookSubscription()
        let projects = URL(fileURLWithPath: string("projectsDir"))
        // A kept capture holds the run's own transcripts (they are moved
        // out of the real projects folder); paths in events still name the
        // real one.
        let runProjects = (manifest["runProjectsDir"] as? String).map { URL(fileURLWithPath: $0) } ?? projects
        let cwd = string("cwd")
        let sessions = manifest["sessions"] as? [String: Any] ?? [:]
        let prompts = manifest["prompts"] as? [String: String] ?? [:]

        if let fresh = sessions["fresh"] as? String {
            checkHeadless(scenario: "fresh", session: fresh, cwd: cwd, projects: projects,
                          expected: [("SessionStart", "startup"), ("UserPromptSubmit", nil), ("Stop", nil), ("SessionEnd", nil)])
            checkTranscript(session: fresh, cwd: cwd, projects: runProjects,
                            firstPrompt: prompts["fresh"], lastPrompt: prompts["resume"])
        } else {
            skip("headless", feature: "Tabs start Claude and know their conversation", "no headless run was captured")
        }
        if let fresh = sessions["fresh"] as? String, sessions["resumeRan"] as? Bool == true {
            checkHeadless(scenario: "resume", session: fresh, cwd: cwd, projects: projects,
                          expected: [("SessionStart", "resume"), ("UserPromptSubmit", nil), ("Stop", nil)])
        }
        if let fork = sessions["fork"] as? String {
            checkHeadless(scenario: "fork", session: fork, cwd: cwd, projects: projects,
                          expected: [("SessionStart", nil), ("UserPromptSubmit", nil), ("Stop", nil)])
        }
        if let tui = sessions["tui"] as? String {
            checkInteractive(session: tui, cleared: sessions["tuiCleared"] as? String, cwd: cwd,
                             projects: projects, runProjects: runProjects, prompt: prompts["tui"])
        }
        checkEffortPicker()
        checkRealConfig(projects: projects)
        checkRecentTranscripts(projects: projects)
    }

    /// The toolbar's effort menu drives Claude Code's `/effort` picker by
    /// its on-screen wording (EffortPicker).
    mutating func checkEffortPicker() {
        let feature = "Effort menu in the toolbar (this session only)"
        guard let open = manifest["effortPickerOpen"] as? String,
              let done = manifest["effortPickerDone"] as? String
        else {
            skip("tui.effortPicker", feature: feature, "the interactive run didn't reach the /effort picker")
            return
        }
        guard EffortPicker.isOpen(onScreen: open) else {
            fail("tui.effortPicker", feature: feature,
                 "the /effort picker no longer says \"s to use this session only … Esc to cancel\": the menu would only beep")
            return
        }
        if let level = EffortPicker.confirmedLevel(onScreen: done), ClaudeEffortChoice.matching(level: level) != nil {
            ok("tui.effortPicker", feature: feature, "the picker set \(level) for this session only")
        } else {
            fail("tui.effortPicker", feature: feature,
                 "after \"s\" no \"Set effort level to … (this session only)\" appeared: the menu can't confirm a pick")
        }
    }

    // MARK: - Hooks

    /// The capture subscribed to the events of the installed hook settings;
    /// the app's list must be the same, or the capture proves nothing.
    mutating func checkHookSubscription() {
        let captured = Set(manifest["subscribedEvents"] as? [String] ?? [])
        let app = Set(ClaudeHookBridge.events)
        if captured == app {
            ok("hooks.subscription", feature: "Tab state (working, finished, needs permission)",
               "the check listened to the same \(app.count) hook events the app subscribes to")
        } else {
            warn("hooks.subscription", feature: "Tab state (working, finished, needs permission)",
                 "the app subscribes to \(app.sorted()) but the check captured \(captured.sorted()); rebuild and relaunch Xylem once so ~/.xylem/hooks is current, then run the check again")
        }
    }

    /// Hook events of a scenario, oldest first.
    func events(_ scenario: String) -> [[String: Any]] {
        let folder = directory.appending(path: "events-\(scenario)")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let order = (try? String(contentsOf: folder.appending(path: "order.txt"), encoding: .utf8))?
            .split(separator: "\n").map(String.init)
        let names = order ?? files.map(\.lastPathComponent).sorted()
        return names.compactMap { name in
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    mutating func checkHeadless(scenario: String, session: String, cwd: String, projects: URL,
                                expected: [(String, String?)]) {
        let feature: String
        switch scenario {
        case "resume": feature = "Tabs reopen their own conversation after a restart"
        case "fork": feature = "A conversation open in another app opens as a copy"
        default: feature = "Tab state and tabs knowing their own conversation"
        }
        let captured = events(scenario)
        guard !captured.isEmpty else {
            fail("hooks.\(scenario).fired", feature: feature,
                 "no hook event arrived from claude started with --settings: Xylem would never see what Claude does")
            return
        }
        let transcript = TerminalSessionFactory.transcriptURL(directory: cwd, sessionID: session, projectsDirectory: projects)?.path
        var problems: [String] = []
        for (name, source) in expected {
            guard let raw = captured.first(where: { $0["hook_event_name"] as? String == name }) else {
                problems.append("\(name) never fired")
                continue
            }
            problems += eventProblems(raw, name: name, source: source, session: session, transcript: transcript)
        }
        if problems.isEmpty {
            ok("hooks.\(scenario)", feature: feature,
               "\(expected.map(\.0).joined(separator: ", ")) arrived with the right session and transcript")
        } else {
            fail("hooks.\(scenario)", feature: feature, problems.joined(separator: "; "))
        }
    }

    /// What the app's parser makes of one event, against what it should be.
    func eventProblems(_ raw: [String: Any], name: String, source: String?, session: String?,
                       transcript: String?) -> [String] {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let event = ClaudeTabEvent.parse(data, at: Date())
        else { return ["\(name): Xylem can't read the event (no hook_event_name?)"] }
        var problems: [String] = []
        switch (name, event.kind) {
        case ("SessionStart", .sessionStart(let got)):
            if let source, got != source { problems.append("SessionStart source is \(got ?? "missing"), expected \(source)") }
        case ("SessionEnd", .sessionEnd): break
        case ("UserPromptSubmit", .promptSubmitted): break
        case ("PreToolUse", .toolActivity), ("PostToolUse", .toolActivity): break
        case ("Stop", .stop): break
        case ("Notification", _): break
        default: problems.append("\(name) is read as \(event.kind)")
        }
        if let session, event.sessionID != session {
            problems.append("\(name) carries session \(event.sessionID ?? "none"), the tab's is \(session)")
        }
        if let transcript, event.transcriptPath != transcript {
            problems.append("\(name) transcript_path is \(event.transcriptPath ?? "missing"), Xylem expects \(transcript)")
        }
        return problems
    }

    mutating func checkInteractive(session: String, cleared: String?, cwd: String, projects: URL,
                                   runProjects: URL, prompt: String?) {
        let captured = events("tui")
        let feature = "Tab state (working, finished, needs permission)"
        let transcript = TerminalSessionFactory.transcriptURL(directory: cwd, sessionID: session, projectsDirectory: projects)?.path
        var problems: [String] = []
        for name in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            guard let raw = captured.first(where: { $0["hook_event_name"] as? String == name }) else {
                problems.append("\(name) never fired")
                continue
            }
            problems += eventProblems(raw, name: name, source: name == "SessionStart" ? "startup" : nil,
                                      session: session, transcript: transcript)
        }
        if problems.isEmpty {
            ok("hooks.tui", feature: feature, "an interactive turn with a tool reported start, tool use and stop")
        } else {
            fail("hooks.tui", feature: feature, problems.joined(separator: "; "))
        }

        // Permission prompt -> the orange mark.
        let notifications = captured.filter { $0["hook_event_name"] as? String == "Notification" }
        let permission = notifications.compactMap { raw -> ClaudeTabEvent? in
            guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return ClaudeTabEvent.parse(data, at: Date())
        }.first { if case .needsInput = $0.kind { return true } else { return false } }
        if permission != nil {
            ok("hooks.permission", feature: "Orange \"needs your permission\" mark",
               "the permission question arrived as a Notification Xylem reads as needs-input")
        } else {
            let types = notifications.compactMap { $0["notification_type"] as? String }
            fail("hooks.permission", feature: "Orange \"needs your permission\" mark",
                 types.isEmpty ? "no Notification arrived for the permission question"
                     : "Notification types were \(types), none Xylem reads as a permission question")
        }
        let knownTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "idle_prompt", "auth_success"]
        let newTypes = Set(notifications.compactMap { $0["notification_type"] as? String }).subtracting(knownTypes)
        if !newTypes.isEmpty {
            warn("hooks.notificationTypes", feature: "Tab state (working, finished, needs permission)",
                 "new notification_type values Xylem ignores: \(newTypes.sorted())")
        }

        // /clear: the tab follows the new session id.
        if let cleared {
            let clearStart = captured.first {
                $0["hook_event_name"] as? String == "SessionStart" && $0["source"] as? String == "clear"
            }
            let clearEnd = captured.first {
                $0["hook_event_name"] as? String == "SessionEnd" && $0["reason"] as? String == "clear"
            }
            var clearProblems: [String] = []
            if clearEnd == nil { clearProblems.append("no SessionEnd with reason clear") }
            if let clearStart, let data = try? JSONSerialization.data(withJSONObject: clearStart),
               let event = ClaudeTabEvent.parse(data, at: Date()) {
                if !event.switchesSession { clearProblems.append("SessionStart(clear) isn't seen as a session switch") }
                if event.sessionID != cleared { clearProblems.append("SessionStart(clear) carries \(event.sessionID ?? "no id")") }
                if event.sessionID == session { clearProblems.append("/clear kept the old session id") }
            } else {
                clearProblems.append("no SessionStart with source clear")
            }
            if clearProblems.isEmpty {
                ok("hooks.clear", feature: "Tabs follow /clear to the new conversation",
                   "SessionEnd(clear) then SessionStart(clear) with a new id")
            } else {
                fail("hooks.clear", feature: "Tabs follow /clear to the new conversation", clearProblems.joined(separator: "; "))
            }
        }

        // The latest prompt typed in the TUI is the tab's preview.
        if let prompt, let url = TerminalSessionFactory.transcriptURL(directory: cwd, sessionID: session, projectsDirectory: runProjects) {
            let last = LastPromptReader.read(from: url)
            if last == prompt {
                ok("prompts.tui", feature: "Tab titles, prompt preview and Cmd+K prompt search",
                   "the prompt typed in the terminal is read back as the human prompt")
            } else {
                fail("prompts.tui", feature: "Tab titles, prompt preview and Cmd+K prompt search",
                     "the typed prompt was read as \(last.map { "\"\($0.prefix(60))\"" } ?? "nothing")")
            }
        }
    }

    // MARK: - Transcript

    mutating func checkTranscript(session: String, cwd: String, projects: URL, firstPrompt: String?, lastPrompt: String?) {
        let folder = SessionFileLocator.encodedFolderName(for: cwd)
        guard let url = TerminalSessionFactory.transcriptURL(directory: cwd, sessionID: session, projectsDirectory: projects),
              FileManager.default.fileExists(atPath: url.path)
        else {
            let found = (try? FileManager.default.contentsOfDirectory(atPath: projects.path))?
                .filter { $0.contains("xylem-claude-check") } ?? []
            fail("transcript.location", feature: "Sessions, Directories, toolbar stats and resume",
                 "no transcript at projects/\(folder)/\(session).jsonl (folders for the check: \(found)); Claude Code changed where or how it names session files")
            return
        }
        ok("transcript.location", feature: "Sessions, Directories, toolbar stats and resume",
           "the transcript is where Xylem looks for it (folder name encoding unchanged)")

        guard let stats = SessionStatsReader().readStats(from: url) else {
            fail("transcript.stats", feature: "Context %, model and cost in the toolbar",
                 "Xylem found no assistant message with usage in the transcript")
            return
        }
        var problems: [String] = []
        if stats.tokens <= 0 { problems.append("0 tokens counted") }
        if stats.costUSD <= 0 { problems.append("cost came out as 0") }
        if stats.modelID.isEmpty { problems.append("no model name") }
        if stats.lastPromptAt == nil { problems.append("no human prompt time") }
        if stats.lastAssistantAt == nil { problems.append("no reply time") }
        if problems.isEmpty {
            ok("transcript.stats", feature: "Context %, model and cost in the toolbar",
               "\(stats.model), \(stats.tokens) tokens, $\(String(format: "%.4f", stats.costUSD))")
        } else {
            fail("transcript.stats", feature: "Context %, model and cost in the toolbar", problems.joined(separator: "; "))
        }
        if let effort = stats.effort {
            if ClaudeEffortChoice.matching(level: effort) != nil {
                ok("transcript.effort", feature: "Effort in the toolbar", "replies carry their effort level (\(effort))")
            } else {
                warn("transcript.effort", feature: "Effort in the toolbar",
                     "replies carry an effort level the menu doesn't know: \(effort)")
            }
        } else {
            warn("transcript.effort", feature: "Effort in the toolbar",
                 "replies carry no effort level; the toolbar shows a dash")
        }
        if !stats.modelID.isEmpty, !ModelPricingCatalog.hasListedPrice(stats.modelID) {
            warn("pricing.liveModel", feature: "Cost in the toolbar and Usage",
                 "\(stats.modelID) has no price row, its cost is estimated from the family")
        }

        if let lastPrompt {
            let last = LastPromptReader.read(from: url)
            if last == lastPrompt {
                ok("prompts.last", feature: "Prompt preview under each tab", "the latest prompt is read correctly")
            } else {
                fail("prompts.last", feature: "Prompt preview under each tab",
                     "expected the latest prompt, got \(last.map { "\"\($0.prefix(60))\"" } ?? "nothing")")
            }
        }
        if let firstPrompt {
            let sessions = ClaudeSessionReader(projectsDirectory: projects).loadSessions(projectDirectory: cwd, limit: 10)
            if let entry = sessions.first(where: { $0.id == session }) {
                if entry.firstPrompt == firstPrompt {
                    ok("sessions.title", feature: "Sessions list in the right panel", "the session is listed with its first prompt as title")
                } else {
                    fail("sessions.title", feature: "Sessions list in the right panel",
                         "title read as \"\((entry.firstPrompt ?? "nothing").prefix(60))\"")
                }
            } else {
                fail("sessions.title", feature: "Sessions list in the right panel",
                     "the session isn't listed for its folder (\(sessions.count) found)")
            }
        }

        // Every usage key is one Xylem knows.
        var unknown = Set<String>()
        var speeds = Set<String>()
        forEachRecord(in: url) { record in
            guard record["type"] as? String == "assistant",
                  let usage = (record["message"] as? [String: Any])?["usage"] as? [String: Any] else { return }
            unknown.formUnion(Set(usage.keys).subtracting(Self.knownUsageKeys))
            if let speed = usage["speed"] as? String { speeds.insert(speed) }
        }
        reportUsageKeys(unknown, speeds: speeds, id: "usage.liveKeys")
    }

    static let knownUsageKeys: Set<String> = [
        "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens",
        "cache_creation", "speed", "service_tier", "server_tool_use", "inference_geo", "iterations",
        "output_tokens_details", "fallback_credit"
    ]

    mutating func reportUsageKeys(_ unknown: Set<String>, speeds: Set<String>, id: String) {
        let newSpeeds = speeds.subtracting(["standard", "fast"])
        if unknown.isEmpty && newSpeeds.isEmpty {
            ok(id, feature: "Usage Dashboard and toolbar costs", "usage fields are the ones Xylem prices")
        } else {
            var parts: [String] = []
            if !unknown.isEmpty { parts.append("new usage fields \(unknown.sorted()) (a new kind of tokens would be left out of costs)") }
            if !newSpeeds.isEmpty { parts.append("new speed values \(newSpeeds.sorted()) (priced as standard)") }
            warn(id, feature: "Usage Dashboard and toolbar costs", parts.joined(separator: "; "))
        }
    }

    // MARK: - The user's own config (read-only)

    mutating func checkRealConfig(projects: URL) {
        let root = URL(fileURLWithPath: string("configRoot"))
        let fm = FileManager.default

        // Plugins
        let pluginsFile = root.appending(path: "plugins/installed_plugins.json")
        if let raw = jsonObject(pluginsFile) {
            let rawCount = (raw["plugins"] as? [String: Any])?.count
            let parsed = InstalledPluginsRegistry(pluginsFile: pluginsFile).loadInstalledPlugins().count
            if let rawCount, rawCount == parsed {
                ok("config.plugins", feature: "Plugins and plugin skills in the right panel", "\(parsed) installed plugins read")
            } else {
                fail("config.plugins", feature: "Plugins and plugin skills in the right panel",
                     "installed_plugins.json has \(rawCount.map(String.init) ?? "no \"plugins\" map") entries, Xylem read \(parsed); top-level keys: \(raw.keys.sorted())")
            }
        } else {
            skip("config.plugins", feature: "Plugins and plugin skills in the right panel", "no installed_plugins.json")
        }

        // Settings
        let settingsFile = root.appending(path: "settings.json")
        if fm.fileExists(atPath: settingsFile.path) {
            if ClaudeSettingsReader(globalSettingsURL: settingsFile).readGlobalSettings() != nil {
                ok("config.settings", feature: "Permissions, hooks and MCP from settings in the right panel", "settings.json reads")
            } else {
                fail("config.settings", feature: "Permissions, hooks and MCP from settings in the right panel",
                     "Xylem can't decode settings.json; top-level keys: \((jsonObject(settingsFile)?.keys.sorted()) ?? [])")
            }
        }

        // MCP from .claude.json
        let globalConfig = URL(fileURLWithPath: string("globalConfigFile"))
        if let raw = jsonObject(globalConfig) {
            let rawUser = (raw["mcpServers"] as? [String: Any])?.count ?? 0
            let rawProjects = (raw["projects"] as? [String: Any]) ?? [:]
            let projectWithServers = rawProjects.first { (($0.value as? [String: Any])?["mcpServers"] as? [String: Any])?.isEmpty == false }
            let reader = ClaudeMcpConfigReader(userConfigURL: globalConfig)
            let user = reader.mcpBindings(projectDirectory: nil).count
            var detail = "\(user) user MCP servers read"
            var good = user == rawUser
            if let (path, value) = projectWithServers {
                let rawLocal = ((value as? [String: Any])?["mcpServers"] as? [String: Any])?.count ?? 0
                // Only the .claude.json entries; the project's .mcp.json adds its own.
                let local = reader.mcpBindings(projectDirectory: path).filter { $0.scope == .local }.count
                good = good && local == rawLocal
                detail += ", \(local) of \(rawLocal) for a project"
            }
            if good {
                ok("config.mcp", feature: "MCP servers in the right panel", detail)
            } else {
                fail("config.mcp", feature: "MCP servers in the right panel",
                     "\(detail) (raw user count \(rawUser)): the .claude.json format changed")
            }
        } else {
            skip("config.mcp", feature: "MCP servers in the right panel", "no readable .claude.json")
        }

        // Agent teams
        let teams = root.appending(path: "teams")
        let configs = ((try? fm.contentsOfDirectory(atPath: teams.path)) ?? [])
            .filter { fm.fileExists(atPath: teams.appending(path: "\($0)/config.json").path) }
        if configs.isEmpty {
            skip("config.teams", feature: "Agent Teams in the right panel", "no agent team on this Mac to compare")
        } else {
            let read = AgentTeamsReader(teamsDirectory: teams).loadTeams()
            let withMembers = read.filter { !$0.members.isEmpty }.count
            if read.count == configs.count, withMembers > 0 {
                ok("config.teams", feature: "Agent Teams in the right panel", "\(read.count) team configs read")
            } else {
                let keys = jsonObject(teams.appending(path: "\(configs[0])/config.json"))?.keys.sorted() ?? []
                warn("config.teams", feature: "Agent Teams in the right panel",
                     "\(configs.count) team configs, Xylem read \(read.count) (\(withMembers) with members); config keys: \(keys)")
            }
        }

        // Folder names of real projects
        var mismatches: [String] = []
        var checked = 0
        for folder in recentTranscripts(projects: projects, limit: 40) {
            guard let cwd = firstCwd(in: folder) else { continue }
            checked += 1
            let expected = SessionFileLocator.encodedFolderName(for: cwd)
            if expected != folder.deletingLastPathComponent().lastPathComponent { mismatches.append(folder.deletingLastPathComponent().lastPathComponent) }
        }
        if checked == 0 {
            skip("projects.encoding", feature: "Directories, Sessions and stats of existing projects", "no recent transcript to compare")
        } else if mismatches.isEmpty {
            ok("projects.encoding", feature: "Directories, Sessions and stats of existing projects",
               "\(checked) recent project folders are named the way Xylem encodes them")
        } else {
            fail("projects.encoding", feature: "Directories, Sessions and stats of existing projects",
                 "\(mismatches.count) of \(checked) folders don't match Xylem's name encoding, e.g. \(mismatches[0])")
        }
    }

    // MARK: - Recent real transcripts written by this version

    mutating func checkRecentTranscripts(projects: URL) {
        let version = string("claudeVersion")
        var models = Set<String>()
        var unknownKeys = Set<String>()
        var speeds = Set<String>()
        var tags = [String: Int]()
        var lines = 0
        var forkMetas = 0
        var forkMetasWithoutTool = 0
        let binaryDate = Date(timeIntervalSince1970: (manifest["binaryMtime"] as? Double) ?? 0)

        for url in recentTranscripts(projects: projects, limit: 60, includeSubagents: true) {
            forEachRecord(in: url) { record in
                guard record["version"] as? String == version else { return }
                lines += 1
                let message = record["message"] as? [String: Any]
                if record["type"] as? String == "assistant", let message, let usage = message["usage"] as? [String: Any] {
                    if let model = message["model"] as? String, model.hasPrefix("claude") { models.insert(model) }
                    unknownKeys.formUnion(Set(usage.keys).subtracting(Self.knownUsageKeys))
                    if let speed = usage["speed"] as? String { speeds.insert(speed) }
                }
                // A user record Xylem takes for a typed prompt but that
                // starts like machine markup: a new marker to filter out.
                if let prompt = UserPromptExtractor.prompt(from: record) {
                    if prompt.hasPrefix("<"), let end = prompt.firstIndex(where: { $0 == ">" || $0 == " " }) {
                        tags[String(prompt[..<end]), default: 0] += 1
                    }
                }
            }
            if url.path.contains("/subagents/") {
                let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
                if let modified = (try? meta.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   modified > binaryDate, let object = jsonObject(meta), object["isFork"] as? Bool == true {
                    forkMetas += 1
                    if case .unknown = SubagentPrefix(meta: object) { forkMetasWithoutTool += 1 }
                }
            }
        }

        if lines == 0 {
            skip("recent.models", feature: "Usage Dashboard and toolbar costs",
                 "no transcript lines written by \(version) yet beyond the check's own")
        } else {
            let unpriced = models.filter { !ModelPricingCatalog.hasListedPrice($0) }
            if unpriced.isEmpty {
                ok("recent.models", feature: "Usage Dashboard and toolbar costs",
                   "every model used with \(version) has a price: \(models.sorted())")
            } else {
                warn("recent.models", feature: "Usage Dashboard and toolbar costs",
                     "no price row for \(unpriced.sorted()): their cost shows as estimated")
            }
            reportUsageKeys(unknownKeys, speeds: speeds, id: "recent.usageKeys")
            let knownMarkup: Set<String> = ["<pasted_content"]
            let newTags = tags.filter { !knownMarkup.contains($0.key) }
            if newTags.isEmpty {
                ok("recent.markers", feature: "Tab titles, prompt preview and Cmd+K prompt search",
                   "no unknown <tag> markers taken for typed prompts")
            } else {
                warn("recent.markers", feature: "Tab titles, prompt preview and Cmd+K prompt search",
                     "records Xylem takes for typed prompts start with \(newTags.keys.sorted()); if Claude Code writes those itself they will show as tab titles")
            }
        }
        if forkMetas == 0 {
            skip("recent.subagentForks", feature: "Subagent costs in Usage",
                 "no forked subagent since this version was installed")
        } else if forkMetasWithoutTool == 0 {
            ok("recent.subagentForks", feature: "Subagent costs in Usage", "\(forkMetas) forked subagents carry toolUseId")
        } else {
            warn("recent.subagentForks", feature: "Subagent costs in Usage",
                 "\(forkMetasWithoutTool) of \(forkMetas) forked subagents have no toolUseId: their copied history is counted twice")
        }
    }

    // MARK: - Helpers

    func string(_ key: String) -> String { manifest[key] as? String ?? "" }

    func jsonObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func forEachRecord(in url: URL, _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] { body(record) }
        }
    }

    func firstCwd(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        for line in head.split(separator: UInt8(ascii: "\n")) {
            if let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let cwd = record["cwd"] as? String { return cwd }
        }
        return nil
    }

    /// Newest transcripts (outside the check's own folder), under 50 MB.
    func recentTranscripts(projects: URL, limit: Int, includeSubagents: Bool = false) -> [URL] {
        let fm = FileManager.default
        let ownFolder = SessionFileLocator.encodedFolderName(for: string("cwd"))
        var found: [(URL, Date)] = []
        for folder in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        where folder.lastPathComponent != ownFolder {
            guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let isSubagent = url.path.contains("/subagents/")
                if isSubagent && !includeSubagents { continue }
                if !isSubagent && url.deletingLastPathComponent() != folder { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values?.contentModificationDate, (values?.fileSize ?? 0) < 50_000_000,
                      Date().timeIntervalSince(modified) < 3 * 86_400 else { continue }
                found.append((url, modified))
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    mutating func ok(_ id: String, feature: String, _ detail: String) { results.append(.init(id: id, status: "ok", feature: feature, detail: detail)) }
    mutating func warn(_ id: String, feature: String, _ detail: String) { results.append(.init(id: id, status: "warn", feature: feature, detail: detail)) }
    mutating func fail(_ id: String, feature: String, _ detail: String) { results.append(.init(id: id, status: "fail", feature: feature, detail: detail)) }
    mutating func skip(_ id: String, feature: String, _ detail: String) { results.append(.init(id: id, status: "skip", feature: feature, detail: detail)) }

    func write(to url: URL) throws {
        let lines = try results.map { result -> String in
            let object = ["id": result.id, "status": result.status, "feature": result.feature, "detail": result.detail]
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
