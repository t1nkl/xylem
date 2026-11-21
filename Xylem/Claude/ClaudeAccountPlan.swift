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
//    allowed, as on a Max plan) changes nothing.
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
    }

    /// The account in the config at `url`; nil when it can't be read.
    static func read(_ url: URL) -> Snapshot? {
        guard let data = SafeFileRead.data(url, limit: readLimit),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let account = object["oauthAccount"] as? [String: Any]
        let id = (account?["accountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Snapshot(accountID: id, unavailableFamilies: unavailableFamilies(object["modelAccessCache"]))
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
