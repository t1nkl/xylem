//
//  UsageModels.swift
//  Xylem
//
//  Immutable value types describing aggregated Claude Code usage across
//  sessions. Each type is closed: the aggregator produces them, the UI only
//  reads them.
//

import Foundation

nonisolated struct UsageTotals: Equatable, Codable {
    var totalCostUSD: Double = 0
    var sessionCount: Int = 0
    var totalTokens: Int = 0
    /// Part of `totalCostUSD` spent by subagents (already included in it).
    var subagentCostUSD: Double = 0
    /// Part of `totalCostUSD` spent on models without a listed price
    /// (`ModelPricingCatalog.hasListedPrice`), priced by their family.
    var estimatedCostUSD: Double = 0

    init(totalCostUSD: Double = 0, sessionCount: Int = 0, totalTokens: Int = 0, subagentCostUSD: Double = 0,
         estimatedCostUSD: Double = 0) {
        self.totalCostUSD = totalCostUSD
        self.sessionCount = sessionCount
        self.totalTokens = totalTokens
        self.subagentCostUSD = subagentCostUSD
        self.estimatedCostUSD = estimatedCostUSD
    }

    private enum CodingKeys: String, CodingKey {
        case totalCostUSD, sessionCount, totalTokens, subagentCostUSD, estimatedCostUSD
    }

    /// `subagentCostUSD` may be missing in a `usage-cache.json` written
    /// before subagents were counted; those numbers still show until the
    /// refresh replaces them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCostUSD = try container.decode(Double.self, forKey: .totalCostUSD)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        subagentCostUSD = try container.decodeIfPresent(Double.self, forKey: .subagentCostUSD) ?? 0
        estimatedCostUSD = try container.decodeIfPresent(Double.self, forKey: .estimatedCostUSD) ?? 0
    }

    var averageCostPerSession: Double {
        guard sessionCount > 0 else { return 0 }
        return totalCostUSD / Double(sessionCount)
    }
}

nonisolated struct ModelUsage: Identifiable, Equatable, Codable {
    var id: String { model }
    let model: String
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheWriteTokens: Int
    let cacheReadTokens: Int
    let totalCostUSD: Double
    /// Some of the row's cost is priced by a fallback rate (a model without
    /// a listed price). Optional so an older `usage-cache.json` decodes.
    var hasEstimatedCost: Bool? = nil
}

nonisolated struct ProjectUsage: Identifiable, Equatable, Codable {
    var id: String { projectPath }
    let projectPath: String
    let sessionCount: Int
    let totalTokens: Int
    let totalCostUSD: Double
}

nonisolated struct SessionUsage: Identifiable, Equatable, Codable {
    let id: String
    let projectPath: String
    let model: String
    let totalTokens: Int
    /// Includes the session's subagents.
    let totalCostUSD: Double
    let startedAt: Date
    /// Part of `totalCostUSD` spent by subagents; nil when there was none.
    /// Optional so a `usage-cache.json` written before it still decodes.
    var subagentCostUSD: Double? = nil
}

nonisolated struct DailyUsage: Identifiable, Equatable, Codable {
    var id: Date { day }
    let day: Date
    let costUSD: Double
    let tokens: Int
}

nonisolated struct UsageDataset: Equatable, Codable {
    var totals: UsageTotals = UsageTotals()
    var byModel: [ModelUsage] = []
    var byProject: [ProjectUsage] = []
    var bySession: [SessionUsage] = []
    var timeline: [DailyUsage] = []
}

nonisolated enum UsageDateRange: CaseIterable, Identifiable {
    case last7, last30, allTime
    var id: Self { self }

    var title: String {
        switch self {
        case .last7:   return "Last 7 Days"
        case .last30:  return "Last 30 Days"
        case .allTime: return "All Time"
        }
    }

    /// Cutoff date; entries before this are excluded. `nil` means no cutoff.
    var cutoff: Date? {
        switch self {
        case .last7:   return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .last30:  return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .allTime: return nil
        }
    }
}
