//
//  ClaudeSettingsDecodingTests.swift
//  XylemTests
//
//  A settings.json layer must survive keys Claude Code allows but we don't
//  model as required. Previously a hook without `command` (prompt/http
//  hooks) failed `decode` for the whole file and that scope vanished from
//  the sidebar - MCP servers, permissions and all.
//

import Testing
import Foundation

struct ClaudeSettingsDecodingTests {

    private func decode(_ json: String) throws -> ClaudeSettings {
        try JSONDecoder().decode(ClaudeSettings.self, from: Data(json.utf8))
    }

    @Test func hookWithoutCommandDoesNotDropTheFile() throws {
        let settings = try decode(#"""
        {
          "mcpServers": {"ctx": {"command": "npx"}},
          "hooks": {
            "Stop": [{"hooks": [{"type": "prompt", "prompt": "Summarise the turn"}]}],
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]}]
          }
        }
        """#)

        #expect(settings.mcpServers?["ctx"]?.command == "npx")
        let stop = try #require(settings.hooks?["Stop"]?.first?.hooks?.first)
        #expect(stop.type == "prompt")
        #expect(stop.command == nil)
        #expect(stop.summary == "Summarise the turn")
        let bash = try #require(settings.hooks?["PreToolUse"]?.first?.hooks?.first)
        #expect(bash.command == "echo hi")
        #expect(bash.summary == "echo hi")
    }

    @Test func hookWithoutTypeDecodes() throws {
        let settings = try decode(#"{"hooks":{"Stop":[{"hooks":[{"command":"x"}]}]}}"#)
        let entry = try #require(settings.hooks?["Stop"]?.first?.hooks?.first)
        #expect(entry.type == nil)
        #expect(entry.command == "x")
    }

    @Test func statusLineWithoutCommandKeepsRestOfFile() throws {
        let settings = try decode(#"{"statusLine":{"padding":0},"permissions":{"allow":["Read"]}}"#)
        #expect(settings.statusLine?.command == nil)
        #expect(settings.permissions?.allow == ["Read"])
    }

    @Test func askPermissionsDecode() throws {
        let settings = try decode(#"""
        {"permissions": {"allow": ["Read"], "ask": ["Bash(git push:*)"], "deny": ["Read(.env)"]}}
        """#)
        #expect(settings.permissions?.ask == ["Bash(git push:*)"])
        #expect(settings.permissions?.allow == ["Read"])
        #expect(settings.permissions?.deny == ["Read(.env)"])
    }

    @Test func askRulesAndCommandlessHooksReachTheMergedSettings() throws {
        let global = try decode(#"""
        {"permissions": {"allow": ["Read"], "ask": ["Bash(git push:*)"], "deny": ["Read(.env)"]},
         "hooks": {"Stop": [{"hooks": [{"type": "prompt", "prompt": "Summarise"}, {"type": "prompt", "prompt": "Summarise"}]}]}}
        """#)
        let effective = EffectiveClaudeSettings.merge(global: global, projectShared: nil, projectLocal: nil, projectLabel: nil)
        #expect(effective.permissionRules.map(\.verb) == [.allow, .ask, .deny])
        // Two identical prompt hooks collapse to one row (unique ForEach id).
        #expect(effective.hookBindings.map(\.command) == ["Summarise"])
    }
}
