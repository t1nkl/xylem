//
//  StatsSnapshot.swift
//  Xylem
//
//  Immutable value object describing the numbers shown in the toolbar.
//  Parsing of live sessions will produce instances of this type; views
//  only format and display them.
//

import Foundation

nonisolated struct StatsSnapshot: Equatable, Sendable {
    var contextUsed: Int = 0
    var contextLimit: Int = 200_000
    var costUSD: Double = 0
    var model: String = ""
    /// Raw model id of the newest assistant message (`claude-opus-5-5`).
    var modelID: String = ""
    /// Effort level of the newest assistant message (`medium`), if the
    /// transcript records one.
    var effort: String?
    /// Timestamp of the newest assistant message.
    var lastAssistantAt: Date?
    /// Timestamp of the newest prompt the human typed. Together with
    /// `lastAssistantAt` it tells when a `/model` pick has taken effect.
    var lastPromptAt: Date?
    var tokens: Int = 0
    var duration: TimeInterval = 0
    var projectPath: String = ""

    var contextFraction: CGFloat {
        guard contextLimit > 0 else { return 0 }
        return min(1.0, CGFloat(contextUsed) / CGFloat(contextLimit))
    }

    var hasUsageData: Bool {
        contextUsed > 0 || costUSD > 0 || tokens > 0 || model != "-"
    }

    var contextDisplay: String {
        guard hasUsageData else { return "-" }
        return "\(Int(contextFraction * 100))%"
    }

    var costDisplay: String {
        guard hasUsageData else { return "-" }
        return String(format: "$%.2f", costUSD)
    }

    var modelDisplay: String { model.isEmpty ? "-" : model }

    var tokensDisplay: String {
        guard tokens > 0 else { return "-" }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    var durationDisplay: String {
        let total = Int(duration)
        if total == 0 { return "0s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    var projectDisplay: String {
        guard !projectPath.isEmpty else { return "-" }
        let components = (projectPath as NSString).pathComponents
        if components.count <= 3 { return projectPath }
        return ".../" + components.suffix(2).joined(separator: "/")
    }
}
