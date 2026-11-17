//
//  RelativeTimeText.swift
//  Xylem
//
//  "Updated 3m ago"-style label that ticks on its own. The Usage Dashboard
//  and the Skills Directory used to keep a 30 s `now` @State at the sheet
//  root, so every tick re-ran the whole sheet body (charts, long lists,
//  filtering). A `TimelineView` scoped to this leaf re-renders only the
//  text.
//
//  Also used for the "5m ago" column of the sidebar Sessions list and the
//  new-tab picker's recent projects: those used to refresh only as a side
//  effect of the whole window re-rendering on every stats tick.
//

import SwiftUI

struct RelativeTimeText: View {
    /// Text placed before the relative time, e.g. "Last updated ".
    var prefix: String = ""
    let date: Date

    var body: some View {
        // Recent dates move every minute; older ones change at most daily,
        // so a page of cards doesn't keep dozens of 30 s timers busy.
        let fresh = Date.now.timeIntervalSince(date) < 3600
        TimelineView(.periodic(from: .now, by: fresh ? 30 : 600)) { context in
            Text(prefix + Self.relative(from: date, now: context.date))
        }
    }

    /// "just now", "5m ago", "3h ago", "4d ago" for the last week, then the
    /// day: "Oct 28" this year, "Oct 28, 2025" before (the
    /// old "dd/MM/yy" read like a year and jumped in after "29d ago").
    static func relative(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        let days = Int(seconds / 86400)
        if days < 7 { return "\(days)d ago" }
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return (sameYear ? thisYearFormatter : olderFormatter).string(from: date)
    }

    // English month names to match the rest of the UI, whatever the
    // system language.
    private static let thisYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let olderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}
