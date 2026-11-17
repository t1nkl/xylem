//
//  SubagentTranscript.swift
//  Xylem
//
//  Claude Code writes every subagent's transcript next to its parent
//  session: `<project>/<session id>/subagents/agent-<id>.jsonl`, plus
//  `agent-<id>.meta.json` (written together with the transcript). Their
//  spend is real spend of the parent session, so Usage counts it there.
//
//  One catch, checked on 724 real files (written by Claude Code 2.1.296 to
//  2.1.32x): a fork (`"isFork": true` in the meta) starts with a copy of
//  messages its parent already paid for - the parent's spawning message for
//  a fork of the main session, the parent agent's whole transcript for a
//  fork of a subagent - with the same message ids (the usage on the copied
//  lines can differ slightly from the original's). The copy always ends with the
//  message carrying the spawning `tool_use` (its id is the meta's
//  `toolUseId`), and no message after it is shared with another file of the
//  session (35 of 35 forks). Plain subagents share nothing with the parent.
//  So in a fork, everything up to and including that message is skipped.
//

import Foundation

/// What the meta file says about how to read a subagent transcript.
nonisolated enum SubagentPrefix: Equatable {
    /// Not a fork: every message is the subagent's own.
    case none
    /// A fork: skip messages up to and including the one whose content has
    /// the `tool_use` with this id.
    case inheritedUntilToolUse(String)
    /// No meta yet, or a fork without `toolUseId`: the copy can't be told
    /// apart. Everything is counted and the file is re-read once it changes.
    case unknown

    /// Reads `agent-<id>.meta.json` next to `transcript`.
    init(transcript: URL) {
        let metaURL = transcript.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            self = .unknown
            return
        }
        self.init(meta: meta)
    }

    init(meta: [String: Any]) {
        guard (meta["isFork"] as? Bool) == true else {
            self = .none
            return
        }
        if let toolUseID = meta["toolUseId"] as? String, !toolUseID.isEmpty {
            self = .inheritedUntilToolUse(toolUseID)
        } else {
            self = .unknown
        }
    }

    /// `message.content` has a `tool_use` block with id `toolUseID`.
    static func message(_ message: [String: Any], hasToolUse toolUseID: String) -> Bool {
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            (block["type"] as? String) == "tool_use" && (block["id"] as? String) == toolUseID
        }
    }
}
