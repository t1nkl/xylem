//
//  SkillsDirectoryFetcher.swift
//  Xylem
//
//  Fetches the full list of skills from skills.sh. There's no public API,
//  but the homepage embeds the initial catalogue inside a Next.js RSC
//  payload - we locate the `initialSkills` array and decode it.
//
//  The page is a few hundred KB: the regex, the un-escaping passes, the
//  bracket scan and the JSON decode all run in a `@concurrent` helper so
//  none of it lands on the main actor after the network await.
//

import Foundation

nonisolated protocol SkillsDirectoryFetching {
    func fetch() async throws -> [MarketplaceSkill]
}

nonisolated struct SkillsDirectoryFetcher: SkillsDirectoryFetching {
    let homepageURL: URL
    let session: URLSession

    init(
        homepageURL: URL = URL(string: "https://skills.sh/")!,
        session: URLSession = .shared
    ) {
        self.homepageURL = homepageURL
        self.session = session
    }

    enum FetchError: LocalizedError {
        case payloadNotFound
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .payloadNotFound: return "Could not find skills data on skills.sh"
            case .decodingFailed:  return "Failed to decode the skills catalogue"
            }
        }
    }

    func fetch() async throws -> [MarketplaceSkill] {
        var request = URLRequest(url: homepageURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return try await Self.parse(data)
    }

    /// HTML → `[MarketplaceSkill]`. `@concurrent` so a caller on the main
    /// actor doesn't do the heavy string work itself.
    @concurrent
    static func parse(_ data: Data) async throws -> [MarketplaceSkill] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw FetchError.payloadNotFound
        }
        guard let jsonString = extractInitialSkillsJSON(from: html) else {
            throw FetchError.payloadNotFound
        }
        guard let jsonData = jsonString.data(using: .utf8) else {
            throw FetchError.decodingFailed
        }
        do {
            return try JSONDecoder().decode([MarketplaceSkill].self, from: jsonData)
        } catch {
            throw FetchError.decodingFailed
        }
    }

    /// Locates the embedded JSON blob that Next.js streams via
    /// `self.__next_f.push`. The string is JSON-escaped inside a quoted JS
    /// string; we reassemble pushes and un-escape what we need.
    static func extractInitialSkillsJSON(from html: String) -> String? {
        // Each push looks like: self.__next_f.push([1,"...encoded..."]) -
        // the encoded string contains initialSkills. We concatenate the raw
        // escaped text across all pushes because Next.js sometimes splits a
        // single payload across multiple pushes.
        let pattern = #"self\.__next_f\.push\(\[1,\s*\"(.*?)\"\s*\]\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        let joined = regex.matches(in: html, range: nsrange)
            .compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: html) else { return nil }
                return String(html[range])
            }
            .joined()

        return unescapedInitialSkills(in: joined)
    }

    private static func unescapedInitialSkills(in encoded: String) -> String? {
        // Unescape the JS string: \" → ", \\ → \, \n → \n.
        let unescaped = encoded
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")

        guard let marker = unescaped.range(of: #""initialSkills":"#) else { return nil }
        let tail = unescaped[marker.upperBound...]
        guard let arrayStart = tail.firstIndex(of: "[") else { return nil }

        // Scan until the matching closing bracket, respecting string quoting.
        var depth = 0
        var inString = false
        var escape = false
        var endIndex: String.Index?

        for index in tail[arrayStart...].indices {
            let ch = tail[index]
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 { endIndex = tail.index(after: index); break }
            }
        }
        guard let end = endIndex else { return nil }
        return String(tail[arrayStart..<end])
    }
}
