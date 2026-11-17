//
//  SkillsRegistry.swift
//  Xylem
//
//  Enumerates the skills Claude Code can load in the current context:
//    · user skills       `~/.claude/skills/<name>/`
//    · project skills    `<project>/.claude/skills/<name>/`
//    · plugin skills     `<installPath>/skills/<name>/` of enabled plugins
//  Scope is attached so the sidebar can label and filter each entry. The
//  enabled plugins are passed in (already read once by the environment
//  loader) instead of re-reading installed_plugins.json here.
//

import Foundation

nonisolated struct InstalledSkill: Identifiable, Hashable, Sendable {
    enum Scope: String, Sendable { case project, plugin, user }

    var id: String { "\(scope.rawValue)/\(pluginID ?? "-")/\(name)" }
    let name: String
    let pluginID: String?
    let pluginName: String?
    let pluginVersion: String?
    let scope: Scope
}

nonisolated protocol SkillsReading {
    /// - Parameter plugins: the plugins enabled for this context.
    func loadSkills(projectDirectory: String?, plugins: [InstalledPlugin]) -> [InstalledSkill]
}

nonisolated struct SkillsRegistry: SkillsReading {
    private let userClaudeOverride: URL?
    var userClaudeDirectory: URL { userClaudeOverride ?? ClaudeConfigDirectory.root }

    init(userClaudeDirectory: URL? = nil) {
        self.userClaudeOverride = userClaudeDirectory
    }

    func loadSkills(projectDirectory: String?, plugins: [InstalledPlugin]) -> [InstalledSkill] {
        var result: [InstalledSkill] = []

        for folder in Self.subfolders(of: userClaudeDirectory.appending(path: "skills")) {
            result.append(InstalledSkill(name: folder.lastPathComponent, pluginID: nil,
                                         pluginName: nil, pluginVersion: nil, scope: .user))
        }

        if let projectDirectory {
            let skills = URL(fileURLWithPath: projectDirectory).appending(path: ".claude/skills")
            for folder in Self.subfolders(of: skills) {
                result.append(InstalledSkill(name: folder.lastPathComponent, pluginID: nil,
                                             pluginName: nil, pluginVersion: nil, scope: .project))
            }
        }

        for plugin in plugins {
            guard let installPath = plugin.installPath else { continue }
            let skills = URL(fileURLWithPath: installPath).appending(path: "skills")
            for folder in Self.subfolders(of: skills) {
                result.append(InstalledSkill(name: folder.lastPathComponent, pluginID: plugin.id,
                                             pluginName: plugin.name, pluginVersion: plugin.version,
                                             scope: .plugin))
            }
        }

        return result.sorted { ($0.scope.rawValue, $0.name) < ($1.scope.rawValue, $1.name) }
    }

    /// A skill is a directory (holding SKILL.md); stray files are ignored.
    private static func subfolders(of url: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
