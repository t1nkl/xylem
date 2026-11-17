//
//  RelativeTimeTextTests.swift
//  XylemTests
//
//  "4d ago" for the last week, then the day in English ("Oct 28", with the
//  year for earlier years) - the old "dd/MM/yy" read like a year.
//

import Testing
import Foundation

struct RelativeTimeTextTests {
    private let now = Date(timeIntervalSince1970: 1_794_700_800)   // 2026-11-15 00:00 UTC

    @Test func recentTimesAreRelative() {
        #expect(RelativeTimeText.relative(from: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(RelativeTimeText.relative(from: now.addingTimeInterval(-300), now: now) == "5m ago")
        #expect(RelativeTimeText.relative(from: now.addingTimeInterval(-3 * 3600), now: now) == "3h ago")
        #expect(RelativeTimeText.relative(from: now.addingTimeInterval(-6 * 86400), now: now) == "6d ago")
    }

    @Test func olderDatesNameTheDay() {
        let weekAgo = now.addingTimeInterval(-8 * 86400)
        let text = RelativeTimeText.relative(from: weekAgo, now: now)
        #expect(text.range(of: #"^[A-Z][a-z]{2} \d{1,2}$"#, options: .regularExpression) != nil)
        let lastYear = now.addingTimeInterval(-400 * 86400)
        let old = RelativeTimeText.relative(from: lastYear, now: now)
        #expect(old.range(of: #"^[A-Z][a-z]{2} \d{1,2}, 2025$"#, options: .regularExpression) != nil)
    }
}
