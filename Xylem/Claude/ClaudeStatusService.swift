//
//  ClaudeStatusService.swift
//  Xylem
//
//  Fetches status.claude.com's public Statuspage summary. Sends nothing
//  about the user; only an `If-None-Match` with the previous ETag, so an
//  unchanged page costs a 304 and no parsing.
//

import Foundation

nonisolated enum ClaudeStatusFetchResult: Sendable {
    case updated(ClaudeServiceStatus, etag: String?)
    case notModified
    case failed
}

nonisolated protocol ClaudeStatusFetching: Sendable {
    func fetch(etag: String?) async -> ClaudeStatusFetchResult
}

nonisolated struct ClaudeStatusService: ClaudeStatusFetching {
    static let summaryURL = URL(string: "https://status.claude.com/api/v2/summary.json")!

    func fetch(etag: String?) async -> ClaudeStatusFetchResult {
        var request = URLRequest(url: Self.summaryURL, timeoutInterval: 10)
        // Ours is the only cache that matters; let the server answer 304.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed }
        if http.statusCode == 304 { return .notModified }
        guard http.statusCode == 200, let status = ClaudeStatusParser.parse(data) else { return .failed }
        return .updated(status, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
