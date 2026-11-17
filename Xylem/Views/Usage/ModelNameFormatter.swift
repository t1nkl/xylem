//
//  ModelNameFormatter.swift
//  Xylem
//
//  Converts internal model IDs like "claude-opus-4-6" or
//  "+synthetics/claude-haiku-4-5-20251001" into human-friendly display names
//  used across the Usage Dashboard.
//

import Foundation

nonisolated enum ModelNameFormatter {
    private static let families = ["fable", "mythos", "opus", "sonnet", "haiku"]

    static func display(_ rawModel: String) -> String {
        let normalized = stripProvider(rawModel).lowercased()
        if normalized.isEmpty { return "Unknown" }

        guard let family = families.first(where: { normalized.contains($0) }) else { return rawModel }
        let base = family.prefix(1).uppercased() + family.dropFirst()

        let version = extractVersion(from: normalized)
        let providerSuffix = providerSuffix(in: rawModel)
        return [base, version, providerSuffix]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
    }

    private static func stripProvider(_ raw: String) -> String {
        guard let slash = raw.firstIndex(of: "/") else { return raw }
        return String(raw[raw.index(after: slash)...])
    }

    private static func providerSuffix(in raw: String) -> String? {
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        let prefix = raw[..<slash].trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        return prefix.isEmpty ? nil : "(\(prefix))"
    }

    /// Picks the version piece: e.g. "4.7" from "claude-opus-4-7". Only the
    /// first two short numeric segments are kept - dated snapshots like
    /// "claude-haiku-4-5-20251001" collapse to "4.5", not "4.5.20251001".
    private static func extractVersion(from normalized: String) -> String? {
        let tokens = normalized.split(separator: "-")
        guard let familyIndex = tokens.firstIndex(where: {
            families.contains(String($0))
        }) else { return nil }

        let versionTokens = tokens
            .suffix(from: tokens.index(after: familyIndex))
            .prefix { $0.count <= 2 && $0.allSatisfy { $0.isNumber } }
            .prefix(2)

        guard !versionTokens.isEmpty else { return nil }
        return versionTokens.joined(separator: ".")
    }
}
