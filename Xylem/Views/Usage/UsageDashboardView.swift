//
//  UsageDashboardView.swift
//  Xylem
//
//  Top-level Usage Dashboard. Shows cached data immediately, overlays a
//  loading indicator while refreshing, and exposes a manual refresh button
//  plus the "last updated" timestamp so the user always knows how stale the
//  numbers are.
//
//  The "last updated" text ticks inside its own TimelineView leaf
//  (RelativeTimeText) - a clock at the sheet root used to rebuild the chart
//  and every table row every 30 s.
//

import SwiftUI

struct UsageDashboardView: View {
    @State var viewModel = UsageDashboardViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Panel = .overview

    enum Panel: String, CaseIterable, Identifiable {
        case overview, byModel, byProject, bySession, timeline
        var id: Self { self }

        var title: String {
            switch self {
            case .overview:  return "Overview"
            case .byModel:   return "By Model"
            case .byProject: return "By Project"
            case .bySession: return "By Session"
            case .timeline:  return "Timeline"
            }
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    metrics
                    tabs
                    content
                }
                .padding(20)
            }
            .opacity(shouldDimContent ? 0.35 : 1)
            .allowsHitTesting(!shouldDimContent)

            // Only while there is nothing to show yet. With saved numbers
            // (every open after the first) the refresh runs behind them and
            // the header's small "Refreshing" indicator is enough.
            if shouldDimContent {
                loadingOverlay
            }
        }
        .background(AppTheme.Colors.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 680)
        .task { await viewModel.loadInitial() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage Dashboard")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                subtitle
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            rangeChips
            refreshButton
            closeButton
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let updated = viewModel.lastUpdated {
            RelativeTimeText(prefix: "Last updated ", date: updated)
        } else if viewModel.isRefreshing {
            Text("Scanning your Claude Code history…")
        } else {
            Text("Track your Claude Code usage and costs")
        }
    }

    private var rangeChips: some View {
        HStack(spacing: 6) {
            ForEach(UsageDateRange.allCases) { range in
                rangeChip(range)
            }
        }
    }

    private func rangeChip(_ range: UsageDateRange) -> some View {
        let isActive = viewModel.range == range
        return Button {
            Task { await viewModel.setRange(range) }
        } label: {
            Text(range.title)
                .font(.system(size: 11, weight: .medium))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .foregroundStyle(isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? AppTheme.Colors.tabBackground : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        // Not disabled while refreshing: every range is in memory, and a
        // range the running scan hasn't produced yet appears when it ends.
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.Colors.textSecondary)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                Text(viewModel.isRefreshing ? "Refreshing" : "Refresh")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Colors.tabBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRefreshing)
    }

    private var closeButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(6)
                .background(
                    Circle().fill(AppTheme.Colors.panelBackground)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metrics & tabs

    private var metrics: some View {
        HStack(spacing: 12) {
            UsageMetricCard(
                title: "Total Cost",
                value: UsageFormatting.money(viewModel.dataset.totals.totalCostUSD),
                caption: UsageFormatting.costCaption(viewModel.dataset.totals)
            )
            UsageMetricCard(title: "Total Sessions", value: UsageFormatting.integer(viewModel.dataset.totals.sessionCount))
            UsageMetricCard(title: "Total Tokens", value: UsageFormatting.compactTokens(viewModel.dataset.totals.totalTokens))
            UsageMetricCard(title: "Avg Cost/Session", value: UsageFormatting.money(viewModel.dataset.totals.averageCostPerSession))
        }
        // Equal-height tiles when only one of them has a caption.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Panel.allCases) { panel in
                let isActive = panel == selectedTab
                Button { selectedTab = panel } label: {
                    Text(panel.title)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(isActive ? AppTheme.Colors.textPrimary : AppTheme.Colors.textSecondary)
                        .background(isActive ? AppTheme.Colors.tabBackground : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Colors.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .overview:
            VStack(alignment: .leading, spacing: 16) {
                UsageTimelineChart(data: viewModel.dataset.timeline)
                UsageByModelTable(rows: viewModel.dataset.byModel)
            }
        case .byModel:   UsageByModelTable(rows: viewModel.dataset.byModel)
        case .byProject: UsageByProjectTable(rows: viewModel.dataset.byProject)
        case .bySession: UsageBySessionTable(rows: viewModel.dataset.bySession)
        case .timeline:  UsageTimelineChart(data: viewModel.dataset.timeline)
        }
    }

    // MARK: - Loading overlay

    private var shouldDimContent: Bool {
        viewModel.isRefreshing && !viewModel.hasCache
    }

    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(AppTheme.Colors.textPrimary)
            Text("Scanning sessions…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text("This takes a few seconds for large histories.")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.Colors.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 20)
    }
}
