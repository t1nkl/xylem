//
//  InstalledPluginsRegistry.swift
//  Xylem
//
//  Models and reader for ~/.claude/plugins/installed_plugins.json.
//

import Foundation

nonisolated struct InstalledPlugin: Identifiable, Hashable, Sendable {
    /// One entry of a plugin's install list. Claude Code installs a plugin
    /// per scope: `user` (every project), or `project` / `local` for one
    /// `projectPath`. The same plugin can be installed several times.
    nonisolated struct Install: Hashable, Sendable {
        let scope: String
        let projectPath: String?
    }

    let id: String      // key as stored: "name@marketplace"
    let name: String
    let marketplace: String
    let version: String
    /// Scope of the first install (what the sidebar shows as detail).
    let scope: String
    let projectPath: String?
    let installPath: String?
    let installs: [Install]

    init(
        id: String,
        name: String,
        marketplace: String,
        version: String,
        scope: String,
        projectPath: String?,
        installPath: String?,
        installs: [Install]? = nil
    ) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.scope = scope
        self.projectPath = projectPath
        self.installPath = installPath
        self.installs = installs ?? [Install(scope: scope, projectPath: projectPath)]
    }

    /// True when one of the installs is scoped to `directory` itself (a
    /// `project` or `local` install), as opposed to a user-wide install.
    func isInstalled(forProject directory: String) -> Bool {
        installs.contains { $0.scope != "user" && $0.projectPath == directory }
    }
}

nonisolated protocol InstalledPluginsReading {
    func loadInstalledPlugins() -> [InstalledPlugin]
}

nonisolated struct InstalledPluginsRegistry: InstalledPluginsReading {
    private let pluginsOverride: URL?
    var pluginsFile: URL {
        pluginsOverride ?? ClaudeConfigDirectory.root.appending(path: "plugins/installed_plugins.json")
    }

    init(pluginsFile: URL? = nil) {
        self.pluginsOverride = pluginsFile
    }

    func loadInstalledPlugins() -> [InstalledPlugin] {
        guard let data = try? Data(contentsOf: pluginsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: [[String: Any]]]
        else { return [] }

        var result: [InstalledPlugin] = []
        for (key, instances) in plugins {
            let (name, marketplace) = splitPluginKey(key)
            guard let first = instances.first else { continue }
            result.append(InstalledPlugin(
                id: key,
                name: name,
                marketplace: marketplace,
                version: first["version"] as? String ?? "",
                scope: first["scope"] as? String ?? "",
                projectPath: first["projectPath"] as? String,
                installPath: first["installPath"] as? String,
                installs: instances.map {
                    InstalledPlugin.Install(
                        scope: $0["scope"] as? String ?? "",
                        projectPath: $0["projectPath"] as? String
                    )
                }
            ))
        }
        return result.sorted { $0.name < $1.name }
    }

    private func splitPluginKey(_ key: String) -> (name: String, marketplace: String) {
        if let atIndex = key.firstIndex(of: "@") {
            return (String(key[..<atIndex]), String(key[key.index(after: atIndex)...]))
        }
        return (key, "")
    }
}
