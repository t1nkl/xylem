//
//  ClaudeAccountPlan.swift
//  Xylem
//
//  The Claude account Claude Code is signed in with, from its global config
//  (`.claude.json`):
//  - `oauthAccount.accountUuid`: the toolbar's plan limits are the
//    account's, and a status line input without `rate_limits` doesn't drop
//    them (every session's inputs have none before its first request), so
//    a `/login` to another account - or to an API key - is told by the id
//    changing, and the limits the old account reported are dropped;
//  - `modelAccessCache`: the models the account's plan includes, as the
//    server told Claude Code (`apiName` + `entitled`). For `/model <alias>`
//    Claude Code steps a refused model down to the newest one of its family
//    the plan includes, and refuses only when there is none (a Pro plan
//    without Opus, say; a live re-check may still let it through), so the
//    model menu greys out such families. An empty list (every model
//    allowed, as on a Max plan) changes nothing;
//  - `cachedUsageUtilization`: Claude Code's last `/usage` answer for the
//    account. The status line gets the plan limits from response headers,
//    which some accounts don't receive; Claude Code then falls back to this
//    answer while it is at most an hour old, and so does the toolbar.
//

import Foundation

nonisolated enum ClaudeAccountPlan {
    /// The config is a few hundred KB; a file over this size is not read.
    static let readLimit = 32 * 1024 * 1024

    struct Snapshot: Equatable, Sendable {
        var accountID: String?
        /// Menu families (`ClaudeModelChoice.family`) whose every listed
        /// model is not entitled.
        var unavailableFamilies: Set<String> = []
        /// The last `/usage` answer for this account, when it has a window.
        var cachedUsage: CachedUsage? = nil
    }

    struct CachedUsage: Equatable, Sendable {
        var limits: ClaudeLiveStatus.RateLimits
        var fetchedAt: Date
    }

    /// How long Claude Code itself trusts a `/usage` answer in place of
    /// the response headers.
    static let cachedUsageLifetime: TimeInterval = 3600

    /// The account in the config at `url`; nil when it can't be read.
    static func read(_ url: URL) -> Snapshot? {
        guard let data = SafeFileRead.data(url, limit: readLimit),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let account = object["oauthAccount"] as? [String: Any]
        let id = (account?["accountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Snapshot(accountID: id, unavailableFamilies: unavailableFamilies(object["modelAccessCache"]),
                        cachedUsage: cachedUsage(object["cachedUsageUtilization"], accountID: id))
    }

    /// `{fetchedAtMs, accountUuid, utilization: {five_hour, seven_day}}`,
    /// each window `{utilization: percent, resets_at: ISO 8601}`; nil when
    /// it is another account's or has no window.
    static func cachedUsage(_ value: Any?, accountID: String?) -> CachedUsage? {
        guard let accountID, let cache = value as? [String: Any],
              cache["accountUuid"] as? String == accountID,
              let fetchedMs = number(cache["fetchedAtMs"]), fetchedMs > 0,
              let utilization = cache["utilization"] as? [String: Any]
        else { return nil }
        func window(_ value: Any?) -> ClaudeLiveStatus.RateLimits.Window? {
            guard let window = value as? [String: Any], let used = number(window["utilization"]) else { return nil }
            return .init(usedPercentage: used, resetsAt: date(window["resets_at"]))
        }
        let limits = ClaudeLiveStatus.RateLimits(fiveHour: window(utilization["five_hour"]),
                                                 sevenDay: window(utilization["seven_day"]))
        guard !limits.isEmpty else { return nil }
        return CachedUsage(limits: limits, fetchedAt: Date(timeIntervalSince1970: fetchedMs / 1000))
    }

    /// A JSON number, not a Bool.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// An ISO 8601 string (microseconds cut to milliseconds, which every
    /// macOS parses) or unix seconds.
    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) { return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil }
        guard let text = value as? String else { return nil }
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return TimestampParser.parse(trimmed)
    }

    /// A family is unavailable when the list has models of it and none is
    /// entitled; a family it doesn't mention stays available.
    static func unavailableFamilies(_ cache: Any?) -> Set<String> {
        guard let entries = cache as? [[String: Any]] else { return [] }
        var entitled: [String: Bool] = [:]
        for entry in entries {
            guard let name = entry["apiName"] as? String, let isEntitled = entry["entitled"] as? Bool,
                  let family = ClaudeModelChoice.matching(modelID: name)?.family
            else { continue }
            entitled[family] = (entitled[family] ?? false) || isEntitled
        }
        return Set(entitled.filter { !$0.value }.keys)
    }

    /// The file's modification time, read fresh (`URL.resourceValues`
    /// caches it on the URL value).
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
