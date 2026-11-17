//
//  ClaudeStatusTests.swift
//  XylemTests
//
//  status.claude.com parsing and the badge's lifecycle. The fixture mirrors
//  the real summary.json shape from the 2026-11-13 incident ("Elevated
//  errors on claude.ai, the Claude API, and Claude Code").
//

import Testing
import Foundation

struct ClaudeStatusParserTests {

    static let incidentDay = #"""
    {"page":{"name":"Claude"},
     "status":{"indicator":"major","description":"Partial System Outage"},
     "components":[
       {"name":"claude.ai","status":"major_outage"},
       {"name":"Claude API (api.anthropic.com)","status":"partial_outage"},
       {"name":"Claude Code","status":"partial_outage"},
       {"name":"Claude Cowork","status":"degraded_performance"}],
     "incidents":[
       {"id":"m365","name":"Elevated errors affecting the Microsoft 365 connector","status":"identified","impact":"major",
        "shortlink":"https://stspg.io/a","components":[{"name":"claude.ai","status":"major_outage"},{"name":"Claude Cowork","status":"degraded_performance"}]},
       {"id":"errors","name":"Elevated errors on claude.ai, the Claude API, and Claude Code","status":"investigating","impact":"major",
        "shortlink":"https://stspg.io/264r547qtkky","components":[{"name":"claude.ai","status":"major_outage"},{"name":"Claude API (api.anthropic.com)","status":"partial_outage"},{"name":"Claude Code","status":"partial_outage"}]}],
     "scheduled_maintenances":[]}
    """#

    static let allClear = #"""
    {"status":{"indicator":"none","description":"All Systems Operational"},
     "components":[{"name":"Claude Code","status":"operational"}],
     "incidents":[],"scheduled_maintenances":[]}
    """#

    @Test func claudeCodeIncidentComesFirstAndSetsTheLevel() throws {
        let status = try #require(ClaudeStatusParser.parse(Data(Self.incidentDay.utf8)))
        #expect(!status.isAllClear)
        #expect(status.level == .partialOutage)
        #expect(status.summary == "Partial System Outage")
        #expect(status.incidents.map(\.id) == ["errors", "m365"])
        #expect(status.headline?.affectsClaudeCode == true)
        #expect(status.incidents.last?.affectsClaudeCode == false)
        #expect(status.headline?.link?.absoluteString == "https://stspg.io/264r547qtkky")
    }

    @Test func otherProductsOnlyKeepTheLevelOperational() throws {
        let json = #"""
        {"status":{"description":"Minor Service Outage"},
         "components":[{"name":"Claude Code","status":"operational"},{"name":"claude.ai","status":"degraded_performance"}],
         "incidents":[{"id":"x","name":"Connector errors","status":"identified","impact":"minor","components":[{"name":"claude.ai","status":"degraded_performance"}]}]}
        """#
        let status = try #require(ClaudeStatusParser.parse(Data(json.utf8)))
        #expect(status.level == .operational)          // muted badge
        #expect(!status.isAllClear)                    // but still listed
        #expect(status.headline?.affectsClaudeCode == false)
    }

    @Test func allClearShowsNothing() throws {
        #expect(try #require(ClaudeStatusParser.parse(Data(Self.allClear.utf8))).isAllClear)
    }

    @Test func maintenanceInProgressIsListed() throws {
        let json = #"""
        {"status":{"description":"Under Maintenance"},
         "components":[{"name":"Claude API (api.anthropic.com)","status":"under_maintenance"}],
         "incidents":[],
         "scheduled_maintenances":[
           {"id":"mx","name":"Database upgrade","status":"in_progress","impact":"maintenance","components":[{"name":"Claude API (api.anthropic.com)","status":"under_maintenance"}]},
           {"id":"later","name":"Next week","status":"scheduled","impact":"maintenance","components":[]}]}
        """#
        let status = try #require(ClaudeStatusParser.parse(Data(json.utf8)))
        #expect(status.level == .maintenance)
        #expect(status.incidents.map(\.id) == ["mx"])
        #expect(status.headline?.status == "maintenance")
    }

    @Test func garbageIsRejected() {
        #expect(ClaudeStatusParser.parse(Data("<html>".utf8)) == nil)
    }
}

/// Scripted fetcher: returns the queued results in order.
nonisolated final class ScriptedStatusFetcher: ClaudeStatusFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ClaudeStatusFetchResult]
    private(set) var sentETags: [String?] = []

    init(_ results: [ClaudeStatusFetchResult]) { self.results = results }

    func fetch(etag: String?) async -> ClaudeStatusFetchResult {
        lock.withLock {
            sentETags.append(etag)
            return results.isEmpty ? .failed : results.removeFirst()
        }
    }
}

@MainActor
struct ClaudeStatusViewModelTests {

    @Test func etagIsReusedAndStaleStatusIsDroppedAfterLongFailure() async throws {
        let status = try #require(ClaudeStatusParser.parse(Data(ClaudeStatusParserTests.incidentDay.utf8)))
        let fetcher = ScriptedStatusFetcher([.updated(status, etag: "W/\"1\""), .notModified, .failed, .failed])
        let model = ClaudeStatusViewModel(fetcher: fetcher, staleAfter: 600)
        let t0 = Date(timeIntervalSince1970: 1_000)

        await model.refresh(now: t0)
        #expect(model.status == status)
        await model.refresh(now: t0.addingTimeInterval(60))          // 304
        #expect(model.status == status)
        await model.refresh(now: t0.addingTimeInterval(120))         // brief failure: keep it
        #expect(model.status == status)
        await model.refresh(now: t0.addingTimeInterval(60 + 601))    // failing > 10 min after the last 304
        #expect(model.status == nil)
        #expect(fetcher.sentETags == [nil, "W/\"1\"", "W/\"1\"", "W/\"1\""])
    }
}
