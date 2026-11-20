//
//  ClaudeSettings.swift
//  Xylem
//
//  Decoded representation of ~/.claude/settings.json. Only the fields we
//  display in the sidebar - we silently ignore unknown keys so user config
//  upgrades don't break parsing.
//
//  Every field that Claude Code itself treats as optional must be optional
//  here too: one missing required key fails `decode` for the whole file,
//  and the reader then drops that entire settings layer without a word.
//

import Foundation

nonisolated struct ClaudeSettings: Decodable {
    let enabledPlugins: [String: Bool]?
    let mcpServers: [String: McpServer]?
    let hooks: [String: [HookGroup]]?
    let permissions: Permissions?
    let statusLine: StatusLine?
    /// Default model (`/model` writes it), e.g. "opus[1m]".
    var model: String?

    struct McpServer: Decodable, Hashable {
        let command: String?
        let args: [String]?
    }

    struct HookGroup: Decodable {
        let matcher: String?
        let hooks: [HookEntry]?
    }

    /// Only `command` hooks have a `command`; `prompt`/`http`/agent hooks
    /// carry other fields, so both keys are optional.
    struct HookEntry: Decodable {
        let type: String?
        let command: String?
        /// Prompt hooks carry their text here instead of a command.
        let prompt: String?
        /// HTTP hooks carry their endpoint here.
        let url: String?

        init(type: String?, command: String?, prompt: String? = nil, url: String? = nil) {
            self.type = type
            self.command = command
            self.prompt = prompt
            self.url = url
        }

        /// What the sidebar shows for this hook: its command, or the prompt
        /// / URL / type for hooks that have no command.
        var summary: String {
            command ?? url ?? prompt ?? "(\(type ?? "unknown") hook)"
        }
    }

    struct Permissions: Decodable {
        let allow: [String]?
        let deny: [String]?
        /// `var` so the memberwise init keeps `ask` defaulted to nil.
        var ask: [String]?
    }

    /// Optional for the same reason as hooks: a malformed `statusLine`
    /// shouldn't take the rest of the file down with it.
    struct StatusLine: Decodable, Equatable {
        let type: String?
        let command: String?
        /// Columns before the line's text (Claude Code's default is 0).
        var padding: Int?
    }
}
