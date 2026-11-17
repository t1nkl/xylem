//
//  SessionExporter.swift
//  Xylem
//
//  Renders a Claude Code session jsonl file as readable Markdown. User and
//  assistant turns become heading blocks; tool calls collapse into a
//  `> Tool: <name>` quote with the input payload + a short result preview
//  so the export reads as a transcript rather than a JSON dump.
//

import Foundation

nonisolated protocol SessionExporting {
    /// Parses `fileURL` (one Claude Code jsonl) and returns a Markdown
    /// document. Non-fatal - unreadable lines are skipped.
    func exportMarkdown(for session: ClaudeSession) -> String
}

nonisolated struct SessionExporter: SessionExporting {
    private let maxToolResultChars = 400

    func exportMarkdown(for session: ClaudeSession) -> String {
        var turns: [Turn] = []
        var currentTurn: Turn?
        let iso = ISO8601DateFormatter()

        JSONLReader.forEachJSONObject(in: session.fileURL) { root in
            let type = root["type"] as? String ?? ""
            let timestampString = root["timestamp"] as? String
            let date = timestampString.flatMap { iso.date(from: $0) }
                ?? timestampString.flatMap { TimestampParser.parse($0) }
            let message = root["message"] as? [String: Any]

            switch type {
            case "user":
                if let text = Self.extractUserText(from: message?["content"]),
                   Self.isRealUserText(text) {
                    if let turn = currentTurn { turns.append(turn) }
                    currentTurn = Turn(kind: .user, timestamp: date, text: text, blocks: [])
                } else if let result = Self.extractToolResult(from: message?["content"]),
                          let existing = currentTurn {
                    // Tool results belong to the most recent assistant turn.
                    currentTurn = existing.appending(.toolResult(result))
                }
            case "assistant":
                guard let content = message?["content"] as? [[String: Any]] else { break }
                if let turn = currentTurn { turns.append(turn) }
                var blocks: [Block] = []
                var assistantText: [String] = []
                for part in content {
                    guard let kind = part["type"] as? String else { continue }
                    switch kind {
                    case "text":
                        if let text = part["text"] as? String, !text.isEmpty {
                            assistantText.append(text)
                        }
                    case "tool_use":
                        let name = part["name"] as? String ?? "unknown"
                        let input = part["input"]
                        blocks.append(.toolUse(name: name, input: Self.formatToolInput(input)))
                    default: break
                    }
                }
                currentTurn = Turn(
                    kind: .assistant,
                    timestamp: date,
                    text: assistantText.joined(separator: "\n\n"),
                    blocks: blocks
                )
            default:
                break
            }
            return true
        }
        if let turn = currentTurn { turns.append(turn) }

        return renderMarkdown(session: session, turns: turns)
    }

    // MARK: - Rendering

    private func renderMarkdown(session: ClaudeSession, turns: [Turn]) -> String {
        var md = ""
        md += "# \(session.title.isEmpty ? "Claude Code Session" : session.title)\n\n"
        md += "> Exported from Xylem - \(Self.formatExportDate(.now))\n"
        md += "> Session: `\(session.id)`  \n"
        md += "> Project: `\(session.projectPath)`  \n"
        md += "> Last modified: \(Self.formatExportDate(session.lastModified))  \n\n"
        md += "---\n\n"

        for turn in turns {
            md += renderTurn(turn)
            md += "\n---\n\n"
        }
        return md
    }

    private func renderTurn(_ turn: Turn) -> String {
        var out = ""
        let heading = turn.kind == .user ? "### 🧑  User" : "### 🤖  Assistant"
        let stamp = turn.timestamp.map { " · \(Self.formatTurnDate($0))" } ?? ""
        out += heading + stamp + "\n\n"
        if !turn.text.isEmpty {
            out += turn.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        for block in turn.blocks {
            switch block {
            case .toolUse(let name, let input):
                out += "> **Tool call:** `\(name)`\n"
                if !input.isEmpty {
                    out += "> \n"
                    for line in input.split(separator: "\n") {
                        out += "> `\(line)`\n"
                    }
                }
                out += "\n"
            case .toolResult(let preview):
                out += "<details><summary>Tool result</summary>\n\n```\n"
                out += preview
                out += "\n```\n\n</details>\n\n"
            }
        }
        return out
    }

    // MARK: - Content extraction

    /// Plain user text (not a tool_result wrapper) and not an internal
    /// command marker like `<local-command-…>`.
    private static func extractUserText(from content: Any?) -> String? {
        if let string = content as? String {
            return string
        }
        if let array = content as? [[String: Any]] {
            // tool_result payloads handled separately - if this is one, skip.
            if array.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return nil
            }
            let texts = array.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
        }
        return nil
    }

    private static func extractToolResult(from content: Any?) -> String? {
        guard let array = content as? [[String: Any]] else { return nil }
        for part in array where (part["type"] as? String) == "tool_result" {
            if let string = part["content"] as? String {
                return Self.truncate(string, limit: 400)
            }
            if let inner = part["content"] as? [[String: Any]] {
                let text = inner.compactMap { $0["text"] as? String }.joined(separator: "\n")
                return Self.truncate(text, limit: 400)
            }
        }
        return nil
    }

    private static func isRealUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("<local-command-") { return false }
        if trimmed.hasPrefix("<command-") { return false }
        if trimmed.hasPrefix("<bash-") { return false }
        return true
    }

    private static func formatToolInput(_ input: Any?) -> String {
        guard let input else { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return Self.truncate(string, limit: 600)
        }
        return String(describing: input)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= limit { return stripped }
        return String(stripped.prefix(limit)) + "\n… (truncated)"
    }

    // Formatters are file-local statics so exporting a big session doesn't
    // instantiate one per turn. Safe to share - DateFormatter is thread-safe
    // for reads once configured.
    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    private static let turnDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func formatExportDate(_ date: Date) -> String {
        exportDateFormatter.string(from: date)
    }

    private static func formatTurnDate(_ date: Date) -> String {
        turnDateFormatter.string(from: date)
    }

    // MARK: - Models

    private enum TurnKind { case user, assistant }

    private struct Turn {
        let kind: TurnKind
        let timestamp: Date?
        let text: String
        let blocks: [Block]

        func appending(_ block: Block) -> Turn {
            Turn(kind: kind, timestamp: timestamp, text: text, blocks: blocks + [block])
        }
    }

    private enum Block {
        case toolUse(name: String, input: String)
        case toolResult(String)
    }
}
