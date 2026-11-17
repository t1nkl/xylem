//
//  UsageTimelineChart.swift
//  Xylem
//
//  Daily cost bar chart using Swift Charts. Falls back to a simple message
//  when there's nothing to show.
//

import SwiftUI
import Charts

struct UsageTimelineChart: View {
    let data: [DailyUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text("Daily Usage")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(AppTheme.Colors.textSecondary)

            if data.isEmpty {
                Text("No usage data in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(data) { item in
                    BarMark(
                        x: .value("Day", item.day, unit: .day),
                        y: .value("Cost", item.costUSD)
                    )
                    .foregroundStyle(AppTheme.Colors.accent)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(AppTheme.Colors.panelBorder)
                        AxisValueLabel().foregroundStyle(AppTheme.Colors.textMuted)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel(format: .dateTime.day().month(.twoDigits))
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    }
                }
                .frame(minHeight: 220)
            }

            Text("Daily Usage Over Time")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(AppTheme.Colors.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
        )
    }
}
