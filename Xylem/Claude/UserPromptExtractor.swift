//
//  UserPromptExtractor.swift
//  Xylem
//
//  One rule for "what did the human type" in a Claude Code jsonl record,
//  shared by the session titles (ClaudeSessionReader) and the tab preview
//  (LastPromptReader).
//
//  A `type: user` record is often not the human: tool results, bare
//  slash-command echoes (`/clear`, `<local-command-stdout>`), background task
//  notifications, interrupt markers, and `isMeta` records that Claude Code
//  injects itself (hook output, skill bodies, image captions - e.g. the
//  "A session-scoped Stop hook is now active…" line `/goal` writes), and
//  compaction summaries ("This session is being continued from a previous
//  conversation…"), which carry `isCompactSummary` but not `isMeta`.
//  A slash command typed WITH arguments counts as the prompt: a session
//  that starts with `/goal fix the build` is titled "/goal fix the build".
//

import Foundation

nonisolated enum UserPromptExtractor {
    /// Text the user typed in this jsonl record, trimmed; nil for anything
    /// Claude Code's machinery wrote.
    static func prompt(from root: [String: Any]) -> String? {
        rawPrompt(from: root)
    }

    private static func rawPrompt(from root: [String: Any]) -> String? {
        guard root["type"] as? String == "user",
              (root["isMeta"] as? Bool) != true,
              (root["isCompactSummary"] as? Bool) != true,
              let message = root["message"] as? [String: Any]
        else { return nil }

        if let string = message["content"] as? String {
            return clean(string)
        }
        guard let parts = message["content"] as? [[String: Any]],
              !parts.contains(where: { ($0["type"] as? String) == "tool_result" })
        else { return nil }
        for part in parts where (part["type"] as? String) == "text" {
            if let text = part["text"] as? String, let prompt = clean(text) {
                return prompt
            }
        }
        return nil
    }

    /// Markers Claude Code writes into user records on its own.
    private static let machinePrefixes = [
        "<local-command-",
        "<command-",
        "<bash-",
        "<task-notification",
        "<system-reminder",
        "[Request interrupted"
    ]

    static func clean(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<command-name>") { return slashCommand(in: trimmed) }
        if machinePrefixes.contains(where: trimmed.hasPrefix) { return nil }
        // A pasted block is the user's own text; show it without the wrapper.
        if trimmed.hasPrefix("<pasted_content"), let open = trimmed.firstIndex(of: ">") {
            trimmed = String(trimmed[trimmed.index(after: open)...])
            if let close = trimmed.range(of: "</pasted_content>", options: .backwards) {
                trimmed.removeSubrange(close.lowerBound...)
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return trimmed
    }

    /// A slash command the user typed with arguments (`/goal fix the build`)
    /// is their prompt; a bare one (`/clear`, `/mcp`) is not, and neither
    /// is a settings command whose argument says nothing about the work
    /// (`/model opus`, `/resume <id>`). Claude Code records it as
    /// `<command-name>/goal</command-name>` + `<command-args>`.
    private static func slashCommand(in text: String) -> String? {
        guard let name = tagContent("command-name", in: text),
              !settingsCommands.contains(name),
              let args = tagContent("command-args", in: text), !args.isEmpty
        else { return nil }
        return name + " " + args
    }

    /// Commands whose arguments configure the session rather than ask for
    /// work; they never become a title or a tab preview.
    private static let settingsCommands: Set<String> = [
        "/model", "/resume", "/compact", "/add-dir", "/config", "/permissions",
        "/output-style", "/effort", "/fast", "/advisor", "/login", "/logout"
    ]

    private static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

