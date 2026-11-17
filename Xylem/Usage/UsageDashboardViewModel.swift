//
//  UsageDashboardViewModel.swift
//  Xylem
//
//  The dashboard opens on the last saved numbers instantly, then brings
//  them up to date in the background: one scan computes every range, and
//  thanks to UsageFileCache it reads only what was appended since the last
//  one (a cold scan happens once). The saved numbers stay on screen while
//  that runs.
//
//  The cache file holds every range, read once off the main actor into
//  `entries`; switching ranges after that is a dictionary lookup. Saves
//  write the in-memory copy back (off-main too) and drop keys from older
//  tariff tables.
//

import Foundation
import Observation

@Observable
final class UsageDashboardViewModel {
    private(set) var dataset = UsageDataset()
    private(set) var isRefreshing = false
    private(set) var lastUpdated: Date?
    private(set) var hasCache: Bool = false
    var range: UsageDateRange = .allTime

    private let aggregator: UsageAggregating
    private let cache: UsageCacheStoring

    /// Every cached range, keyed by `UsageCache.rangeKey`. nil until the
    /// first off-main load completes.
    @ObservationIgnored private var entries: [String: UsageCacheEntry]?
    /// The in-flight initial load, shared so a chip tap during it waits for
    /// the same read instead of treating the range as a cache miss.
    @ObservationIgnored private var loadTask: Task<[String: UsageCacheEntry], Never>?

    init(
        aggregator: UsageAggregating = UsageAggregator(),
        cache: UsageCacheStoring = UsageCache()
    ) {
        self.aggregator = aggregator
        self.cache = cache
    }

    /// Shows the saved numbers, then refreshes them.
    func loadInitial() async {
        let all = await cachedEntries()
        if let entry = all[UsageCache.rangeKey(range)] { show(entry) }
        await refresh()
    }

    /// Re-aggregates every range in one scan and replaces the cache.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let fresh = await aggregator.aggregateAll()
        let now = Date()
        // Only current keys: entries priced with an older tariff table are
        // dropped instead of piling up in the file.
        var all: [String: UsageCacheEntry] = [:]
        for (range, dataset) in fresh {
            let key = UsageCache.rangeKey(range)
            all[key] = UsageCacheEntry(range: key, dataset: dataset, updatedAt: now)
        }
        entries = all
        // The range may have changed while scanning; show whichever is
        // selected now.
        if let entry = all[UsageCache.rangeKey(range)] { show(entry) }
        // Awaited before clearing `isRefreshing` so two saves can never
        // land out of order (refresh is not re-entrant).
        await Self.saveAll(all, to: UncheckedSendable(cache))
        isRefreshing = false
    }

    func setRange(_ newRange: UsageDateRange) async {
        guard newRange != range else { return }
        range = newRange
        let all = await cachedEntries()
        guard range == newRange else { return }
        if let entry = all[UsageCache.rangeKey(newRange)] {
            show(entry)
        } else {
            if dataset != UsageDataset() { dataset = UsageDataset() }
            if lastUpdated != nil { lastUpdated = nil }
            if hasCache { hasCache = false }
            // A scan already running covers every range and will show this
            // one when it finishes.
            if !isRefreshing { await refresh() }
        }
    }

    // MARK: - Private

    private func show(_ entry: UsageCacheEntry) {
        if dataset != entry.dataset { dataset = entry.dataset }
        if lastUpdated != entry.updatedAt { lastUpdated = entry.updatedAt }
        if !hasCache { hasCache = true }
    }

    private func cachedEntries() async -> [String: UsageCacheEntry] {
        if let entries { return entries }
        let task: Task<[String: UsageCacheEntry], Never>
        if let loadTask {
            task = loadTask
        } else {
            let cache = UncheckedSendable(self.cache)
            task = Task { await Self.loadAll(from: cache) }
            loadTask = task
        }
        let loaded = await task.value
        // A refresh may have filled `entries` while we were waiting.
        if let entries { return entries }
        entries = loaded
        return loaded
    }

    @concurrent nonisolated
    private static func loadAll(from cache: UncheckedSendable<UsageCacheStoring>) async -> [String: UsageCacheEntry] {
        Dictionary(
            cache.value.loadAll().map { ($0.range, $0) },
            uniquingKeysWith: { _, last in last }
        )
    }

    @concurrent nonisolated
    private static func saveAll(
        _ entries: [String: UsageCacheEntry],
        to cache: UncheckedSendable<UsageCacheStoring>
    ) async {
        try? cache.value.saveAll(entries.values.sorted { $0.range < $1.range })
    }
}
