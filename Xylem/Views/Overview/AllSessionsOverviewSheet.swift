//
//  AllSessionsOverviewSheet.swift
//  Xylem
//
//  Grid-of-cards view of every open tab ("All Sessions" sheet) -
//  clicking a card jumps to that tab, and each card shows live
//  context/cost/model/tokens/duration pulled from the tab's jsonl. Cost
//  and tokens also include the session's subagents
//  (SessionStatsSubagents.swift); the context bar stays the main
//  conversation's.
//
//  Refreshes run in a single `.task` loop that is auto-cancelled on sheet
//  dismiss, and each tab's latest-file mtime is cached so unchanged tabs
//  short-circuit the rescan.
//
//  Render hygiene: a background tick only writes state that actually
//  changed (stats per tab; the spinner is reserved for the manual Refresh),
//  the mtime bookkeeping lives in a non-observed box, the wall-clock
//  duration ticks in a TimelineView inside the card instead of being a
//  time-derived prop on every card, and the last prompt is read from
//  `tab.lastPrompt` (kept current by TabActivityViewModel) instead of
//  re-parsing the jsonl here.
//

import SwiftUI
import AppKit

struct AllSessionsOverviewSheet: View {
    let tabs: TabsViewModel
    @Environment(\.dismiss) private var dismiss
    /// Cost and tokens include the session's subagents; context does not.
    @State private var statsByTabID: [TerminalTab.ID: StatsSnapshot] = [:]
    /// Part of the cost above spent by subagents.
    @State private var subagentCostByTabID: [TerminalTab.ID: Double] = [:]
    /// Plain reference box: the body never reads mtimes, so updating them
    /// must not invalidate the sheet the way an @State write would.
    @State private var mtimes = MtimeBox()
    @State private var isLoading = false

    private let reader = SessionStatsReader()
    private let refreshInterval: Duration = .seconds(6)

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(tabs.tabs) { tab in
                        OverviewCard(
                            tab: tab,
                            stats: statsByTabID[tab.id],
                            subagentCost: subagentCostByTabID[tab.id],
                            onSelect: { select(tab) }
                        )
                    }
                }
                .padding(2)
            }
        }
        .padding(20)
        .background(AppTheme.Colors.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 720, minHeight: 520)
        .task {
            // A single long-running loop makes cancellation on dismiss clean.
            await refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard !Task.isCancelled else { break }
                await refreshAll()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("All Sessions")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("\(tabs.tabs.count) open · auto-refreshed every 6s")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                Task { await refreshAll(force: true) }
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small).tint(AppTheme.Colors.textSecondary)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                    Text("Refresh").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(AppTheme.Colors.tabBackground))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(6)
                    .background(Circle().fill(AppTheme.Colors.panelBackground))
            }
            .buttonStyle(.plain)
        }
    }

    private func select(_ tab: TerminalTab) {
        tabs.select(tab.id)
        dismiss()
    }

    private func refreshAll(force: Bool = false) async {
        // Only the manual Refresh shows the spinner; flipping it on every
        // 6 s background tick re-rendered the whole sheet twice per tick.
        if force { isLoading = true }
        defer { if force { isLoading = false } }
        let sessionsSnapshot = tabs.tabs
            .compactMap { tab -> (TerminalTab.ID, String, URL?, Date?)? in
                guard let dir = tab.session?.configuration.workingDirectory else { return nil }
                return (tab.id, dir, tab.transcriptURL, force ? nil : mtimes.byTabID[tab.id])
            }

        await withTaskGroup(of: (TerminalTab.ID, RefreshOutcome).self) { group in
            for (id, dir, transcript, previousMtime) in sessionsSnapshot {
                group.addTask { [reader] in
                    let outcome = await Self.refresh(dir: dir, transcript: transcript, previousMtime: previousMtime, reader: reader)
                    return (id, outcome)
                }
            }
            for await (id, outcome) in group {
                guard !Task.isCancelled else { break }
                switch outcome {
                case .unchanged:
                    continue
                case let .updated(mtime, stats, subagentCost):
                    mtimes.byTabID[id] = mtime
                    if let stats, statsByTabID[id] != stats { statsByTabID[id] = stats }
                    if subagentCostByTabID[id] != subagentCost { subagentCostByTabID[id] = subagentCost }
                case .missing:
                    mtimes.byTabID.removeValue(forKey: id)
                }
            }
        }
    }

    private final class MtimeBox {
        var byTabID: [TerminalTab.ID: Date] = [:]
    }

    private nonisolated enum RefreshOutcome {
        case unchanged
        /// Snapshot with subagent cost and tokens added; the subagents'
        /// share of the cost (nil when they spent nothing).
        case updated(Date, StatsSnapshot?, Double?)
        case missing
    }

    /// A bound tab reads its own transcript; an unbound one the folder's
    /// newest session. The session's subagents (`<session>/subagents/`)
    /// add to cost and tokens, so a tab whose agents are busy while the
    /// main transcript is quiet still refreshes: the short-circuit mtime is
    /// the newest of all those files.
    @concurrent nonisolated private static func refresh(dir: String, transcript: URL?, previousMtime: Date?, reader: SessionStatsReader) async -> RefreshOutcome {
        let candidate = transcript ?? SessionFileLocator.latestSessionFile(for: dir)
        guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let subagents = SessionSubagentStatsReader()
        let mainMtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        let mtime = max(mainMtime, subagents.newestModification(forTranscript: url) ?? .distantPast)
        if let previousMtime, previousMtime == mtime { return .unchanged }

        var stats = reader.readStats(from: url)
        let spend = subagents.spend(forTranscript: url)
        if !spend.isEmpty {
            stats?.costUSD += spend.costUSD
            stats?.tokens += spend.tokens
        }
        return .updated(mtime, stats, spend.isEmpty ? nil : spend.costUSD)
    }
}

private struct OverviewCard: View {
    let tab: TerminalTab
    let stats: StatsSnapshot?
    /// Subagents' share of `stats.costUSD`.
    let subagentCost: Double?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var costValue: String {
        guard let stats else { return "-" }
        guard let subagentCost, let share = UsageFormatting.subagentAmount(subagentCost) else { return stats.costDisplay }
        return "\(stats.costDisplay) · \(share)"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cwdDisplay)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(tab.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }

                contextBar

                VStack(alignment: .leading, spacing: 4) {
                    keyValue(label: "Model", value: modelValue)
                    keyValue(label: "Tokens", value: stats?.tokensDisplay ?? "-")
                    keyValue(label: "Cost", value: costValue)
                    durationRow
                }

                if let lastPrompt = tab.lastPrompt, !lastPrompt.isEmpty {
                    Text("\"\(lastPrompt)\"")
                        .font(.system(size: 11))
                        .italic()
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }

                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppTheme.Colors.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovering ? AppTheme.Colors.accent.opacity(0.5) : AppTheme.Colors.panelBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var cwdDisplay: String {
        tab.workingDirectory.map { (($0 as NSString).pathComponents.suffix(2).joined(separator: "/")) } ?? "-"
    }

    private var modelValue: String {
        guard let stats, !stats.model.isEmpty else { return "-" }
        return "\(stats.model)\(contextSuffix(stats.contextLimit))"
    }

    private func contextSuffix(_ limit: Int) -> String {
        guard limit >= 1_000_000 else { return "" }
        let millions = Double(limit) / 1_000_000
        let rounded = millions.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(millions))"
            : String(format: "%.1f", millions)
        return " (\(rounded)M context)"
    }

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(AppTheme.Colors.tabBackground)
                    .frame(height: 6)
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppTheme.Colors.accent)
                        .frame(width: proxy.size.width * (stats?.contextFraction ?? 0), height: 6)
                }
                .frame(height: 6)
            }
            HStack {
                Spacer()
                Text(stats?.contextDisplay ?? "-")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
        }
    }

    private func keyValue(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    /// Session duration from the jsonl when known; otherwise wall-clock time
    /// since the tab's shell started, ticking in a TimelineView so only this
    /// row re-renders (a time-derived prop would re-diff the whole card and
    /// reset its hover animation).
    @ViewBuilder
    private var durationRow: some View {
        if let stats {
            keyValue(label: "Duration", value: Self.formatDuration(stats.duration))
        } else if let createdAt = tab.session?.createdAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                keyValue(
                    label: "Duration",
                    value: Self.formatDuration(context.date.timeIntervalSince(createdAt))
                )
            }
        } else {
            keyValue(label: "Duration", value: Self.formatDuration(0))
        }
    }

    private static func formatDuration(_ d: TimeInterval) -> String {
        let total = max(0, Int(d))
        if total == 0 { return "0s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private var statusColor: Color {
        switch tab.state {
        case .picker: return AppTheme.Colors.textMuted
        case .session: return AppTheme.Colors.statusGreen
        }
    }

    private var statusText: String {
        switch tab.state {
        case .picker: return "Waiting for folder"
        case .session: return "Idle"
        }
    }
}
