//
//  UsageBySessionTable.swift
//  Xylem
//
//  Per-session breakdown ordered by most recent start time.
//

import SwiftUI

struct UsageBySessionTable: View {
    let rows: [SessionUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if rows.isEmpty {
                Text("No sessions in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // Lazy: the dashboard's outer ScrollView only builds rows
                // that scroll into view (up to 200 sessions, many projects).
                LazyVStack(spacing: 0) {
                    ForEach(rows.prefix(200)) { row in
                        SessionRow(row: row)
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

private struct SessionRow: View {
    let row: SessionUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.id)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.projectPath)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ModelNameFormatter.display(row.model))
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .frame(width: 140, alignment: .trailing)
            Text(UsageFormatting.compactTokens(row.totalTokens))
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 60, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 3) {
                Text(UsageFormatting.money(row.totalCostUSD))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                // Subagent spend is folded into the session; this line says
                // how much of the cost it was.
                if let cost = row.subagentCostUSD, let share = UsageFormatting.subagentAmount(cost) {
                    Text(share)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .help("Spent by this session's subagents (included in the total)")
                }
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }
}
