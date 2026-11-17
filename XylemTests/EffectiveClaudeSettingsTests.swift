//
//  EffectiveClaudeSettingsTests.swift
//  XylemTests
//
//  Three-scope merge rules - later scopes override plugin enable-map,
//  collections union, statusLine is last-wins. Uses JSON decoding rather
//  than crafted initializers so the fixture shape matches real
//  settings.json exactly.
//

import Testing
import Foundation

struct EffectiveClaudeSettingsTests {

    private func decode(_ json: String) throws -> ClaudeSettings {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(ClaudeSettings.self, from: data)
    }

    @Test func enabledPluginsOverrideAcrossScopes() throws {
        let global = try decode(#"{"enabledPlugins":{"a@m":true,"b@m":true}}"#)
        let shared = try decode(#"{"enabledPlugins":{"b@m":false,"c@m":true}}"#)
        let local = try decode(#"{"enabledPlugins":{"c@m":false,"d@m":true}}"#)

        let effective = EffectiveClaudeSettings.merge(
            global: global,
            projectShared: shared,
            projectLocal: local,
            projectLabel: "demo"
        )
        #expect(effective.enabledPluginIDs == Set(["a@m", "d@m"]))
    }

    @Test func mcpBindingsCarryScopeLabelsAndUnion() throws {
        let global = try decode(#"{"mcpServers":{"g":{"command":"g-cmd"}}}"#)
        let shared = try decode(#"{"mcpServers":{"s":{"command":"s-cmd","args":["--foo"]}}}"#)

        let effective = EffectiveClaudeSettings.merge(
            global: global, projectShared: shared, projectLocal: nil, projectLabel: "demo"
        )
        let byName = Dictionary(uniqueKeysWithValues: effective.mcpBindings.map { ($0.name, $0) })
        #expect(byName["g"]?.scope == .global)
        #expect(byName["s"]?.scope == .project)
        #expect(byName["s"]?.command.contains("--foo") == true)
    }

    @Test func permissionRulesAreUnionedWithScopeInfo() throws {
        let global = try decode(#"{"permissions":{"allow":["Read"],"deny":["Bash"]}}"#)
        let local = try decode(#"{"permissions":{"allow":["Write"]}}"#)
        let effective = EffectiveClaudeSettings.merge(
            global: global, projectShared: nil, projectLocal: local, projectLabel: "demo"
        )
        #expect(effective.permissionRules.count == 3)
        let allows = effective.permissionRules.filter { $0.verb == .allow }.map(\.rule)
        let denies = effective.permissionRules.filter { $0.verb == .deny }.map(\.rule)
        #expect(Set(allows) == Set(["Read", "Write"]))
        #expect(denies == ["Bash"])
    }

    @Test func statusLineFollowsLastWinsPrecedence() throws {
        let global = try decode(#"{"statusLine":{"type":"command","command":"global"}}"#)
        let shared = try decode(#"{"statusLine":{"type":"command","command":"shared"}}"#)
        let effective = EffectiveClaudeSettings.merge(
            global: global, projectShared: shared, projectLocal: nil, projectLabel: nil
        )
        #expect(effective.statusLineCommand == "shared")
    }

    @Test func scopeLabelReflectsProjectContext() {
        let global = EffectiveClaudeSettings.merge(
            global: nil, projectShared: nil, projectLocal: nil, projectLabel: nil
        )
        #expect(global.scopeLabel == "Global")

        let project = EffectiveClaudeSettings.merge(
            global: nil, projectShared: nil, projectLocal: nil, projectLabel: "backend"
        )
        #expect(project.scopeLabel == "Project: backend")
    }
}
