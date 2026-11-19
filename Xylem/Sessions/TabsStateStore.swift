//
//  TabsStateStore.swift
//  Xylem
//
//  Persists the flat list of tabs to ~/.xylem/tabs-state.json. Sessions
//  aren't persisted literally - each tab records its working directory,
//  whether the user renamed it and the Claude session it is bound to; on
//  restore it gets a fresh shell that resumes that session.
//
//  Encoding and the atomic write run on a private serial queue: saves fire
//  on every tab mutation (debounced by TabsViewModel), and a synchronous
//  write on main shows up as a hitch while dragging tabs. The queue being
//  serial is what keeps "newest write wins" - saves land in call order.
//

import Foundation

nonisolated struct PersistedTab: Codable, Sendable {
    let id: UUID
    let title: String
    let workingDirectory: String?
    /// True once the user renamed the tab. Without it a restored tab would go
    /// back to tracking its cwd and lose the custom name on relaunch.
    let hasCustomTitle: Bool
    /// The Claude session the tab was bound to; a relaunch resumes it.
    let claudeSessionID: String?
    /// The session `claudeSessionID` was forked from (open in another app at
    /// restore) while the fork has no transcript yet - Claude Code writes it
    /// with the first message. A relaunch before that resumes this one.
    let forkedFromSessionID: String?

    init(
        id: UUID,
        title: String,
        workingDirectory: String?,
        hasCustomTitle: Bool = false,
        claudeSessionID: String? = nil,
        forkedFromSessionID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.hasCustomTitle = hasCustomTitle
        self.claudeSessionID = claudeSessionID
        self.forkedFromSessionID = forkedFromSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory, hasCustomTitle, claudeSessionID, forkedFromSessionID
    }

    /// Files written before `hasCustomTitle` existed must still decode - a
    /// synthesized decoder would fail the whole file and wipe every tab.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        hasCustomTitle = try container.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        claudeSessionID = try container.decodeIfPresent(String.self, forKey: .claudeSessionID)
        forkedFromSessionID = try container.decodeIfPresent(String.self, forKey: .forkedFromSessionID)
    }
}

nonisolated struct PersistedTabsState: Codable, Sendable {
    var tabs: [PersistedTab]
    var activeTabID: UUID?
}

protocol TabsStateStoring {
    func load() -> PersistedTabsState?
    /// May complete asynchronously; saves are applied in call order.
    func save(_ state: PersistedTabsState)
    /// Blocks until every save issued so far is on disk.
    func flush()
}

extension TabsStateStoring {
    /// Synchronous stores (tests) have nothing in flight.
    func flush() {}
}

struct TabsStateStore: TabsStateStoring {
    static let shared = TabsStateStore()

    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "dev.xylem.tabs-state-store", qos: .utility)

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = home.appendingPathComponent(".xylem/tabs-state.json")
        }
    }

    func load() -> PersistedTabsState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedTabsState.self, from: data)
    }

    func save(_ state: PersistedTabsState) {
        let url = fileURL
        writeQueue.async {
            Self.write(state, to: url)
        }
    }

    func flush() {
        writeQueue.sync {}
    }

    private nonisolated static func write(_ state: PersistedTabsState, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persistence failure is non-fatal - the next save will retry.
        }
    }
}
