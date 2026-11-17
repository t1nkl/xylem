//
//  UsageByProjectTable.swift
//  Xylem
//
//  Breakdown by project directory.
//

import SwiftUI

struct UsageByProjectTable: View {
    let rows: [ProjectUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage by Project")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if rows.isEmpty {
                Text("No usage data in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // Lazy: the dashboard's outer ScrollView only builds rows
                // that scroll into view (up to 200 sessions, many projects).
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        ProjectRow(row: row)
                        Divider().background(AppTheme.Colors.panelBorder)
                    }
                }
            }
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

private struct ProjectRow: View {
    let row: ProjectUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text((row.projectPath as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(row.projectPath)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(row.sessionCount) sessions")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(UsageFormatting.compactTokens(row.totalTokens))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 70, alignment: .trailing)
            Text(UsageFormatting.money(row.totalCostUSD))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}
