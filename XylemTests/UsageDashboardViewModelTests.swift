//
//  UsageDashboardViewModelTests.swift
//  XylemTests
//
//  The dashboard reads the multi-range cache file once, shows the saved
//  numbers right away, then refreshes every range with one scan and writes
//  the set back (dropping stale keys). Fake cache + aggregator - nothing
//  touches ~/.xylem.
//

import Testing
import Foundation

@MainActor
struct UsageDashboardViewModelTests {

    // MARK: - Test doubles

    final class FakeCache: UsageCacheStoring {
        var stored: [UsageCacheEntry] = []
        var loadCount = 0
        var savedSnapshots: [[UsageCacheEntry]] = []
        func loadAll() -> [UsageCacheEntry] {
            loadCount += 1
            return stored
        }
        func saveAll(_ entries: [UsageCacheEntry]) throws {
            savedSnapshots.append(entries)
        }
    }

    /// Returns `sessions` for every range, distinct per range so a test can
    /// tell which one is on screen (allTime = n, last30 = n + 1, last7 = n + 2).
    nonisolated final class FakeAggregator: UsageAggregating {
        var calls = 0
        var sessions = 9
        /// When set, the scan waits until `release()`.
        var gate: CheckedContinuation<Void, Never>?
        var holds = false

        func aggregateAll() async -> [UsageDateRange: UsageDataset] {
            calls += 1
            if holds { await withCheckedContinuation { gate = $0 } }
            return [
                .allTime: UsageDashboardViewModelTests.dataset(sessions: sessions),
                .last30: UsageDashboardViewModelTests.dataset(sessions: sessions + 1),
                .last7: UsageDashboardViewModelTests.dataset(sessions: sessions + 2)
            ]
        }

        func release() {
            holds = false
            gate?.resume()
            gate = nil
        }
    }

    nonisolated static func dataset(sessions: Int) -> UsageDataset {
        UsageDataset(totals: UsageTotals(totalCostUSD: Double(sessions), sessionCount: sessions, totalTokens: sessions))
    }

    private func entry(_ range: UsageDateRange, sessions: Int) -> UsageCacheEntry {
        UsageCacheEntry(range: UsageCache.rangeKey(range), dataset: Self.dataset(sessions: sessions), updatedAt: Date())
    }

    // MARK: - Tests

    @Test func savedNumbersShowWhileTheRefreshRuns() async {
        let cache = FakeCache()
        cache.stored = [entry(.allTime, sessions: 3)]
        let aggregator = FakeAggregator()
        aggregator.holds = true
        let vm = UsageDashboardViewModel(aggregator: aggregator, cache: cache)

        let load = Task { await vm.loadInitial() }
        while aggregator.gate == nil { await Task.yield() }
        // Scan in flight: the cached numbers are on screen, not a blank.
        #expect(vm.isRefreshing)
        #expect(vm.hasCache)
        #expect(vm.dataset == Self.dataset(sessions: 3))

        aggregator.release()
        await load.value
        #expect(!vm.isRefreshing)
        #expect(vm.dataset == Self.dataset(sessions: 9))
    }

    @Test func oneScanFillsEveryRangeAndRangeSwitchesUseMemory() async throws {
        let cache = FakeCache()
        let aggregator = FakeAggregator()
        let vm = UsageDashboardViewModel(aggregator: aggregator, cache: cache)

        await vm.loadInitial()
        await vm.setRange(.last30)
        #expect(vm.dataset == Self.dataset(sessions: 10))
        await vm.setRange(.last7)
        #expect(vm.dataset == Self.dataset(sessions: 11))

        #expect(aggregator.calls == 1)
        #expect(cache.loadCount == 1)
        let saved = try #require(cache.savedSnapshots.last)
        #expect(Set(saved.map(\.range)) == Set(UsageDateRange.allCases.map(UsageCache.rangeKey)))
    }

    @Test func saveDropsKeysFromOlderTariffs() async throws {
        let cache = FakeCache()
        cache.stored = [
            UsageCacheEntry(range: "allTime", dataset: Self.dataset(sessions: 1), updatedAt: Date()),
            UsageCacheEntry(range: "allTime@pricing3", dataset: Self.dataset(sessions: 2), updatedAt: Date()),
            entry(.allTime, sessions: 3)
        ]
        let vm = UsageDashboardViewModel(aggregator: FakeAggregator(), cache: cache)

        await vm.loadInitial()

        let saved = try #require(cache.savedSnapshots.last)
        #expect(!saved.contains { $0.range == "allTime" || $0.range == "allTime@pricing3" })
        #expect(saved.count == UsageDateRange.allCases.count)
    }

    @Test func switchingToAnUncachedRangeDuringAScanWaitsForIt() async {
        let cache = FakeCache()
        cache.stored = [entry(.allTime, sessions: 3)]
        let aggregator = FakeAggregator()
        aggregator.holds = true
        let vm = UsageDashboardViewModel(aggregator: aggregator, cache: cache)

        let load = Task { await vm.loadInitial() }
        while aggregator.gate == nil { await Task.yield() }
        await vm.setRange(.last7)          // not cached yet; the running scan covers it
        #expect(aggregator.calls == 1)

        aggregator.release()
        await load.value
        #expect(vm.range == .last7)
        #expect(vm.dataset == Self.dataset(sessions: 11))
    }
}
