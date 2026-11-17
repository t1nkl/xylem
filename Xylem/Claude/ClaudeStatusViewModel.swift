//
//  ClaudeStatusViewModel.swift
//  Xylem
//
//  Holds the latest status.claude.com state for the header badge. Polled
//  once a minute by AppModel's shared loop (only while a Xylem window is
//  visible). A failed fetch keeps the last known state for a while, then
//  drops it: an old incident must not linger on screen when we simply
//  can't reach the status page.
//

import Foundation
import Observation

@Observable
final class ClaudeStatusViewModel {
    /// nil until the first successful fetch, and after a long outage of the
    /// status page itself.
    private(set) var status: ClaudeServiceStatus?

    @ObservationIgnored private let fetcher: ClaudeStatusFetching
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var lastSuccess: Date?
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private let staleAfter: TimeInterval

    init(fetcher: ClaudeStatusFetching = ClaudeStatusService(), staleAfter: TimeInterval = 10 * 60) {
        self.fetcher = fetcher
        self.staleAfter = staleAfter
    }

    func refresh(now: Date = Date()) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        switch await fetcher.fetch(etag: etag) {
        case let .updated(fresh, newTag):
            etag = newTag
            lastSuccess = now
            if status != fresh { status = fresh }
        case .notModified:
            lastSuccess = now
        case .failed:
            if let lastSuccess, now.timeIntervalSince(lastSuccess) > staleAfter, status != nil {
                status = nil
                etag = nil
            }
        }
    }
}
