//
//  ClaudeMcpConfigReader.swift
//  Xylem
//
//  Claude Code keeps most MCP servers outside settings.json:
//    · `~/.claude.json` → top-level `mcpServers`            (user scope)
//    · `~/.claude.json` → `projects[<dir>].mcpServers`      (local scope)
//    · `<dir>/.mcp.json` → `mcpServers`                     (project scope)
//  Reading only settings.json misses most of them. This reader returns
//  all three as scope-labelled bindings.
//
//  `~/.claude.json` is rewritten by Claude Code on every session, so it is
//  read on demand (environment reload), never watched.
//

import Foundation

nonisolated protocol ClaudeMcpConfigReading: Sendable {
    func mcpBindings(projectDirectory: String?) -> [EffectiveClaudeSettings.McpBinding]
}

nonisolated struct ClaudeMcpConfigReader: ClaudeMcpConfigReading {
    private let userConfigOverride: URL?
    /// `.claude.json`: in the home folder, or in CLAUDE_CONFIG_DIR when set.
    var userConfigURL: URL { userConfigOverride ?? ClaudeConfigDirectory.globalConfigFile }

    init(userConfigURL: URL? = nil) {
        self.userConfigOverride = userConfigURL
    }

    func mcpBindings(projectDirectory: String?) -> [EffectiveClaudeSettings.McpBinding] {
        var result: [EffectiveClaudeSettings.McpBinding] = []
        // The user's own file, rewritten by Claude Code every session: it
        // grows past tens of MB with long histories, so no size cap here
        // (regular file only, like the project's).
        if let user = Self.decode(UserConfig.self, at: userConfigURL, limit: .max) {
            result += Self.bindings(user.mcpServers, scope: .global)
            if let projectDirectory {
                result += Self.bindings(user.projects?[projectDirectory]?.mcpServers, scope: .local)
            }
        }
        if let projectDirectory {
            let mcpJSON = URL(fileURLWithPath: projectDirectory).appending(path: ".mcp.json")
            result += Self.bindings(Self.decode(McpFile.self, at: mcpJSON)?.mcpServers, scope: .project)
        }
        return result
    }

    // MARK: - Private

    /// Only the keys we need; JSONDecoder skips the rest of the (large,
    /// frequently rewritten) user config.
    private nonisolated struct UserConfig: Decodable {
        let mcpServers: [String: Server]?
        let projects: [String: ProjectEntry]?
    }

    private nonisolated struct ProjectEntry: Decodable {
        let mcpServers: [String: Server]?
    }

    private nonisolated struct McpFile: Decodable {
        let mcpServers: [String: Server]?
    }

    /// stdio servers carry `command` + `args`; http/sse servers carry `url`.
    private nonisolated struct Server: Decodable {
        let command: String?
        let args: [String]?
        let url: String?

        var summary: String {
            if let command {
                return ([command] + (args ?? [])).joined(separator: " ")
            }
            return url ?? ""
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL,
                                             limit: Int = SafeFileRead.defaultLimit) -> T? {
        guard let data = SafeFileRead.data(url, limit: limit) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func bindings(
        _ servers: [String: Server]?,
        scope: EffectiveClaudeSettings.Scope
    ) -> [EffectiveClaudeSettings.McpBinding] {
        (servers ?? [:])
            .map { EffectiveClaudeSettings.McpBinding(name: $0.key, command: $0.value.summary, scope: scope) }
            .sorted { $0.name < $1.name }
    }
}
