//
//  AgentsRegistry.swift
//  Xylem
//
//  Enumerates the agents Claude Code can use in the current context:
//    · user agents     `~/.claude/agents/*.md`
//    · project agents  `<project>/.claude/agents/*.md`
//    · plugin agents   `<installPath>/agents/*.md` of enabled plugins
//  Frontmatter (name, description, team) is parsed from the head of each
//  file only, so a long agent prompt is never read in full. The enabled
//  plugins are passed in rather than re-read from installed_plugins.json.
//

import Foundation

nonisolated struct InstalledAgent: Identifiable, Hashable, Sendable {
    enum Scope: String, Sendable { case project, plugin, user }

    var id: String { "\(scope.rawValue)/\(pluginID ?? "-")/\(name)" }
    let name: String
    let description: String?
    let fileURL: URL
    let pluginID: String?
    let pluginName: String?
    let pluginVersion: String?
    let scope: Scope
    /// Team name declared via the `team` frontmatter key (or the plugin name
    /// for plugin-scoped agents so plugin authors can ship ready-made teams
    /// without boilerplate).
    let team: String?
}

nonisolated protocol AgentsReading {
    /// - Parameter plugins: the plugins enabled for this context.
    func loadAgents(projectDirectory: String?, plugins: [InstalledPlugin]) -> [InstalledAgent]
}

nonisolated struct AgentsRegistry: AgentsReading {
    private let userClaudeOverride: URL?
    var userClaudeDirectory: URL { userClaudeOverride ?? ClaudeConfigDirectory.root }

    init(userClaudeDirectory: URL? = nil) {
        self.userClaudeOverride = userClaudeDirectory
    }

    func loadAgents(projectDirectory: String?, plugins: [InstalledPlugin]) -> [InstalledAgent] {
        var result: [InstalledAgent] = []

        func add(_ folder: URL, scope: InstalledAgent.Scope, plugin: InstalledPlugin?) {
            for url in Self.markdownFiles(in: folder) {
                let parsed = Self.parse(fileURL: url)
                result.append(InstalledAgent(
                    name: parsed.name,
                    description: parsed.description,
                    fileURL: url,
                    pluginID: plugin?.id,
                    pluginName: plugin?.name,
                    pluginVersion: plugin?.version,
                    scope: scope,
                    team: parsed.team ?? plugin?.name
                ))
            }
        }

        add(userClaudeDirectory.appending(path: "agents"), scope: .user, plugin: nil)
        if let projectDirectory {
            add(URL(fileURLWithPath: projectDirectory).appending(path: ".claude/agents"), scope: .project, plugin: nil)
        }
        for plugin in plugins {
            guard let installPath = plugin.installPath else { continue }
            add(URL(fileURLWithPath: installPath).appending(path: "agents"), scope: .plugin, plugin: plugin)
        }

        return result.sorted { ($0.scope.rawValue, $0.name) < ($1.scope.rawValue, $1.name) }
    }

    private static func markdownFiles(in folder: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "md" }
    }

    /// Parses YAML frontmatter from an agent markdown file. Falls back to the
    /// filename stem when `name` is missing so every file yields a usable row.
    static func parse(fileURL: URL) -> (name: String, description: String?, team: String?) {
        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        // Frontmatter sits at the top; 8 KB covers it without reading a
        // long agent prompt. A multi-byte character cut at the boundary only
        // affects the body, which is never parsed.
        guard let handle = SafeFileRead.handle(fileURL) else { return (fallbackName, nil, nil) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024),
              let text = (0...3).lazy.compactMap({ String(data: data.dropLast($0), encoding: .utf8) }).first
        else { return (fallbackName, nil, nil) }

        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (fallbackName, nil, nil)
        }

        var name: String?
        var description: String?
        var team: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon]).lowercased()
                let value = String(trimmed[trimmed.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch key {
                case "name": name = value
                case "description": description = value
                case "team", "group": team = value
                default: break
                }
            }
        }
        return (name ?? fallbackName, description, team)
    }
}
