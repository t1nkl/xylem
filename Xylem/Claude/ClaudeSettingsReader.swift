//
//  ClaudeSettingsReader.swift
//  Xylem
//
//  Reads ~/.claude/settings.json. Defined behind a protocol so views can be
//  unit-tested with a stub without touching the real filesystem.
//

import Foundation

nonisolated protocol ClaudeSettingsReading {
    /// Global `~/.claude/settings.json`.
    func readGlobalSettings() -> ClaudeSettings?

    /// Per-project `<project>/.claude/settings.json` (shared) and
    /// `settings.local.json` (user-only). Either may be missing.
    func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?)
}

nonisolated struct ClaudeSettingsReader: ClaudeSettingsReading {
    private let globalSettingsOverride: URL?
    /// The user's settings.json in the Claude config folder, looked up per
    /// read so a changed CLAUDE_CONFIG_DIR applies at once.
    var globalSettingsURL: URL {
        globalSettingsOverride ?? ClaudeConfigDirectory.root.appending(path: "settings.json")
    }

    init(globalSettingsURL: URL? = nil) {
        self.globalSettingsOverride = globalSettingsURL
    }

    func readGlobalSettings() -> ClaudeSettings? {
        decode(at: globalSettingsURL)
    }

    func readProjectSettings(at projectDirectory: String) -> (shared: ClaudeSettings?, local: ClaudeSettings?) {
        let base = URL(fileURLWithPath: projectDirectory)
            .appending(path: ".claude", directoryHint: .isDirectory)
        return (
            shared: decode(at: base.appending(path: "settings.json")),
            local:  decode(at: base.appending(path: "settings.local.json"))
        )
    }

    private func decode(at url: URL) -> ClaudeSettings? {
        guard let data = SafeFileRead.data(url) else { return nil }
        return try? JSONDecoder().decode(ClaudeSettings.self, from: data)
    }
}
