//
//  UsageHelpPopover.swift
//  Xylem
//
//  The Usage Dashboard's "?" button and the popover it opens: what the
//  numbers mean and how UsageAggregator and ModelPricingCatalog count them,
//  in plain words. Any change to those rules belongs here too.
//

import SwiftUI

/// "?" next to the dashboard title; opens `UsageHelpPopover`.
struct UsageHelpButton: View {
    @State private var showsHelp = false

    var body: some View {
        Button { showsHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("How usage is counted")
        .accessibilityLabel("How usage is counted")
        .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
            UsageHelpPopover()
        }
    }
}

/// What the Usage Dashboard counts and how, in plain words.
struct UsageHelpPopover: View {
    struct HelpSection: Identifiable {
        var id: String { title }
        let title: String
        let points: [String]
    }

    static let sections: [HelpSection] = [
        HelpSection(title: "Where the numbers come from", points: [
            "Claude Code's transcripts in ~/.claude/projects (or CLAUDE_CONFIG_DIR), read on this Mac only. The numbers are never sent anywhere.",
            "Every session counts, including ones run outside Xylem."
        ]),
        HelpSection(title: "Cost is an estimate", points: [
            "Each reply is priced at its model's API list price: input, output, cache reads and cache writes (5-minute writes at 1.25x the input price, 1-hour at 2x). Fast mode costs 2x, and long prompts cost more on models with a long-prompt rate.",
            "It is what the same usage would cost through the API, not your bill or subscription.",
            "A model without a listed price uses its family's newest price and is marked \"estimated\"."
        ]),
        HelpSection(title: "Tokens", points: [
            "Input, output, cache reads and cache writes added up. Claude Code writes a reply on several lines; each reply counts once."
        ]),
        HelpSection(title: "Subagents", points: [
            "Counted in the session that started them, not as sessions of their own. A forked subagent's copy of its parent's conversation is skipped."
        ]),
        HelpSection(title: "Sessions and dates", points: [
            "A session counts once in a range when any of its replies falls in it. Avg Cost/Session is Total Cost divided by Total Sessions.",
            "Last 7 Days is today and the 6 days before (Last 30 Days: 29), in your Mac's time zone. Only the days in the range count."
        ]),
        HelpSection(title: "Updates", points: [
            "Saved numbers show at once and refresh in the background when the dashboard opens or you click Refresh. Only new transcript lines are read."
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How usage is counted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            ForEach(Self.sections) { section in
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    ForEach(section.points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                                .accessibilityHidden(true)
                            Text(point)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
    }
}
