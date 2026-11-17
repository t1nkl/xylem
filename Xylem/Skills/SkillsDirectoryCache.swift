//
//  SkillsDirectoryCache.swift
//  Xylem
//
//  Persists the fetched skills catalogue so the sheet opens instantly on
//  subsequent launches. The catalogue changes slowly, so a 6-hour TTL keeps
//  it fresh enough without hammering skills.sh.
//
//  The file is ~100 KB of JSON, so the view model only calls load/save from
//  `@concurrent` helpers - everything here is `nonisolated` for that.
//

import Foundation

nonisolated struct SkillsDirectoryCacheEntry: Codable, Equatable, Sendable {
    let skills: [MarketplaceSkill]
    let updatedAt: Date
}

nonisolated protocol SkillsDirectoryCacheStoring {
    func load() -> SkillsDirectoryCacheEntry?
    func save(_ entry: SkillsDirectoryCacheEntry) throws
}

nonisolated struct SkillsDirectoryCache: SkillsDirectoryCacheStoring {
    let cacheURL: URL

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".xylem/skills-directory-cache.json")
    }

    func load() -> SkillsDirectoryCacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SkillsDirectoryCacheEntry.self, from: data)
    }

    func save(_ entry: SkillsDirectoryCacheEntry) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entry)
        try data.write(to: cacheURL, options: .atomic)
    }
}
