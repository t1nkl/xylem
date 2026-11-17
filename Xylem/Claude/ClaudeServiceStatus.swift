//
//  ClaudeServiceStatus.swift
//  Xylem
//
//  What status.claude.com says right now, reduced to what the header needs:
//  is anything wrong, how bad, and which incidents matter for working in
//  Claude Code. Built from the Statuspage `api/v2/summary.json` payload by
//  a pure function, so the "what to show" rules are unit-tested without a
//  network.
//
//  Relevance: Xylem drives Claude Code, which talks to the Claude API. An
//  incident touching either component is shown first and in full colour;
//  incidents that only touch other products (claude.ai connectors, Cowork,
//  cloud platforms) are still listed, but muted.
//

import Foundation

nonisolated struct ClaudeServiceStatus: Equatable, Sendable {
    /// Severity, ordered so `max()` picks the worst.
    enum Level: Int, Comparable, Sendable {
        case operational, maintenance, degraded, partialOutage, majorOutage

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Statuspage component status (`partial_outage`, …).
        init(componentStatus: String) {
            switch componentStatus {
            case "degraded_performance": self = .degraded
            case "partial_outage": self = .partialOutage
            case "major_outage": self = .majorOutage
            case "under_maintenance": self = .maintenance
            default: self = .operational
            }
        }

        /// Statuspage incident impact (`none`, `minor`, `major`, `critical`).
        init(impact: String) {
            switch impact {
            case "minor": self = .degraded
            case "major": self = .partialOutage
            case "critical": self = .majorOutage
            case "maintenance": self = .maintenance
            default: self = .degraded   // an open incident is never "fine"
            }
        }
    }

    nonisolated struct Incident: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// investigating / identified / monitoring / in progress …
        let status: String
        let level: Level
        let components: [String]
        /// Touches Claude Code or the Claude API.
        let affectsClaudeCode: Bool
        let link: URL?
    }

    /// Worst level among what affects Claude Code (incidents and component
    /// states); `.operational` when only other products have trouble.
    let level: Level
    /// Open incidents, Claude Code ones first.
    let incidents: [Incident]
    /// Overall page description ("Partial System Outage").
    let summary: String

    /// Nothing open anywhere: the header shows nothing.
    var isAllClear: Bool { incidents.isEmpty && level == .operational }

    /// The incident the header names.
    var headline: Incident? { incidents.first }

    static let pageURL = URL(string: "https://status.claude.com")!
}

// MARK: - Parsing

nonisolated enum ClaudeStatusParser {
    /// Components that matter when working in Claude Code.
    static func isClaudeCodeComponent(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("claude code") || lower.contains("claude api") || lower.contains("api.anthropic.com")
    }

    static func parse(_ data: Data) -> ClaudeServiceStatus? {
        guard let payload = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }

        let open = payload.incidents.map { incident(from: $0) }
            + (payload.scheduledMaintenances ?? [])
                .filter { $0.status == "in_progress" }
                .map { incident(from: $0, maintenance: true) }
        // Claude Code first, then worst first; stable otherwise.
        let sorted = open.enumerated().sorted { a, b in
            if a.element.affectsClaudeCode != b.element.affectsClaudeCode { return a.element.affectsClaudeCode }
            if a.element.level != b.element.level { return a.element.level > b.element.level }
            return a.offset < b.offset
        }.map(\.element)

        let componentLevel = payload.components
            .filter { isClaudeCodeComponent($0.name) }
            .map { ClaudeServiceStatus.Level(componentStatus: $0.status) }
            .max() ?? .operational
        let incidentLevel = sorted.filter(\.affectsClaudeCode).map(\.level).max() ?? .operational

        return ClaudeServiceStatus(
            level: max(componentLevel, incidentLevel),
            incidents: sorted,
            summary: payload.status.description
        )
    }

    private static func incident(from raw: RawIncident, maintenance: Bool = false) -> ClaudeServiceStatus.Incident {
        let names = (raw.components ?? []).map(\.name)
        return ClaudeServiceStatus.Incident(
            id: raw.id,
            name: raw.name,
            status: maintenance ? "maintenance" : raw.status,
            level: maintenance ? .maintenance : ClaudeServiceStatus.Level(impact: raw.impact ?? "minor"),
            components: names,
            affectsClaudeCode: names.contains(where: isClaudeCodeComponent),
            link: raw.shortlink.flatMap(URL.init(string:))
        )
    }

    // Only the keys we read; the payload has many more.
    private nonisolated struct Summary: Decodable {
        let status: PageStatus
        let components: [Component]
        let incidents: [RawIncident]
        let scheduledMaintenances: [RawIncident]?

        enum CodingKeys: String, CodingKey {
            case status, components, incidents
            case scheduledMaintenances = "scheduled_maintenances"
        }
    }

    private nonisolated struct PageStatus: Decodable {
        let description: String
    }

    private nonisolated struct Component: Decodable {
        let name: String
        let status: String
    }

    private nonisolated struct RawIncident: Decodable {
        let id: String
        let name: String
        let status: String
        let impact: String?
        let shortlink: String?
        let components: [Component]?
    }
}
