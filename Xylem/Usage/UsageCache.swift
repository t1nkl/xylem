//
//  UsageCache.swift
//  Xylem
//
//  Persists aggregated usage data so the dashboard opens instantly after the
//  first full scan. One entry per date range; a refresh rewrites every range
//  from one scan and drops keys of older tariff tables.
//
//  The API is whole-file (load all / save all): the view model reads the
//  file once off-main into memory, so a range-chip tap is a dictionary
//  lookup and a save never re-reads and re-decodes what's already in RAM.
//

import Foundation

nonisolated struct UsageCacheEntry: Codable, Equatable {
    let range: String              // raw value of UsageDateRange for stable keys
    let dataset: UsageDataset
    let updatedAt: Date
}

nonisolated protocol UsageCacheStoring {
    /// Every stored entry (all ranges). Empty when the file is missing or
    /// unreadable.
    func loadAll() -> [UsageCacheEntry]
    /// Replaces the file with exactly `entries`.
    func saveAll(_ entries: [UsageCacheEntry]) throws
}

nonisolated struct UsageCache: UsageCacheStoring {
    let cacheURL: URL

    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".xylem/usage-cache.json")
    }

    func loadAll() -> [UsageCacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([UsageCacheEntry].self, from: data)) ?? []
    }

    func saveAll(_ entries: [UsageCacheEntry]) throws {
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: cacheURL, options: .atomic)
    }

    /// The pricing version is part of the key, so a dataset computed with old
    /// rates is never shown after a rate change.
    static func rangeKey(_ range: UsageDateRange) -> String {
        let base: String
        switch range {
        case .last7:   base = "last7"
        case .last30:  base = "last30"
        case .allTime: base = "allTime"
        }
        return "\(base)@pricing\(ModelPricingCatalog.version)"
    }
}
