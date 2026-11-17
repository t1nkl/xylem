//
//  PromptHistorySearch.swift
//  Xylem
//
//  The searchable form of the prompt index: one flat list, newest first,
//  each prompt with a case- and diacritic-folded UTF-8 copy for matching.
//
//  Folding happens once per snapshot (off main), so a keystroke costs one
//  fold of the query plus `memmem` over the folded bytes, stopping at the
//  first `limit` hits - newest first means the hits it stops at are the
//  ones shown. Folding is applied to both sides, so "FIX" finds "fix",
//  "cafe" finds "café" and "ПРИВІТ" finds "привіт"; it also folds "й" into
//  "и" and "ї" into "і", the price of diacritic-insensitivity in Ukrainian.
//
//  Folded offsets don't map back onto the original text (folding can change
//  lengths), so the visible match is located again on the original string,
//  only for the rows shown (`snippet`).
//

import Foundation

/// One searchable prompt, flattened from the per-file index.
nonisolated struct PromptHistoryEntry: Identifiable, Hashable, Sendable {
    /// Transcript path + position: unique and stable across refreshes.
    let id: String
    let text: String
    let date: Date?
    let sessionID: String
    let projectPath: String
    let transcriptURL: URL
    /// The session's first prompt, shortened like the session list's
    /// titles; becomes the tab title when the session is resumed.
    let sessionTitle: String

    var projectName: String { (projectPath as NSString).lastPathComponent }
}

nonisolated final class PromptHistorySnapshot: Sendable {
    /// Newest first; prompts without a timestamp last.
    let entries: [PromptHistoryEntry]
    private let folded: [[UInt8]]

    init(records: some Sequence<PromptHistoryFileRecord>) {
        // Newest file first, so a prompt repeated by a fork (same uuid) is
        // kept in the session that was used last.
        let files = records.sorted { lhs, rhs in
            (lhs.stamp.mtimeSeconds, lhs.stamp.mtimeNanoseconds, lhs.path)
                > (rhs.stamp.mtimeSeconds, rhs.stamp.mtimeNanoseconds, rhs.path)
        }
        var seen = Set<String>()
        var entries: [PromptHistoryEntry] = []
        // Throwaway runs in temp folders stay out, like Directories and
        // Sessions (`TemporaryProjectFilter`). Filtered here, not in the
        // index, so changing the rule never re-reads a transcript.
        for file in files where !TemporaryProjectFilter.isTemporary(path: file.projectPath) {
            let url = URL(fileURLWithPath: file.path)
            let title = file.prompts.first.map { Self.title(from: $0.text) } ?? file.sessionID
            for (index, prompt) in file.prompts.enumerated() {
                if let uuid = prompt.uuid, !seen.insert(uuid).inserted { continue }
                entries.append(PromptHistoryEntry(
                    id: "\(file.path)#\(index)",
                    text: prompt.text,
                    date: prompt.time.map(Date.init(timeIntervalSince1970:)),
                    sessionID: file.sessionID,
                    projectPath: file.projectPath,
                    transcriptURL: url,
                    sessionTitle: title
                ))
            }
        }
        entries.sort { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?): return l != r ? l > r : lhs.id < rhs.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.id < rhs.id
            }
        }
        self.entries = entries
        self.folded = entries.map { Array(Self.fold($0.text).utf8) }
    }

    var count: Int { entries.count }

    static let minimumQueryLength = 2

    /// Up to `limit` prompts containing `query` (folded, whitespace
    /// collapsed), newest first. A query shorter than 2 characters matches
    /// nothing: one letter hits almost every prompt.
    func search(_ query: String, limit: Int = 20) -> [PromptHistoryEntry] {
        let normalized = PromptHistoryIndexer.normalized(query)
        guard normalized.count >= Self.minimumQueryLength else { return [] }
        let needle = Array(Self.fold(normalized).utf8)
        guard !needle.isEmpty else { return [] }
        var hits: [PromptHistoryEntry] = []
        needle.withUnsafeBytes { needleBytes in
            for (index, haystack) in folded.enumerated() where haystack.count >= needleBytes.count {
                let found = haystack.withUnsafeBytes { bytes in
                    memmem(bytes.baseAddress, bytes.count, needleBytes.baseAddress, needleBytes.count) != nil
                }
                guard found else { continue }
                hits.append(entries[index])
                if hits.count == limit { break }
            }
        }
        return hits
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func title(from text: String, maxLength: Int = 60) -> String {
        text.count <= maxLength ? text : String(text.prefix(maxLength)) + "…"
    }
}

/// A prompt cut down to the part around the match, for one palette row.
nonisolated struct PromptHistorySnippet: Equatable {
    /// Text before the match; starts with "…" when the prompt was cut.
    let before: String
    let match: String
    let after: String

    /// Characters of context kept before the match.
    static let leadingContext = 40

    /// The prompt with the first match of `query` marked; the whole prompt
    /// as `before` when the folded match can't be located on the original
    /// (rare: folds that change length, e.g. "ß" vs "ss").
    init(text: String, query: String) {
        let needle = PromptHistoryIndexer.normalized(query)
        guard !needle.isEmpty,
              let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            before = text
            match = ""
            after = ""
            return
        }
        let start = text.index(range.lowerBound, offsetBy: -Self.leadingContext, limitedBy: text.startIndex) ?? text.startIndex
        let lead = String(text[start..<range.lowerBound])
        before = start == text.startIndex ? lead : "…" + lead
        match = String(text[range])
        after = String(text[range.upperBound...])
    }
}
