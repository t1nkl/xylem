//
//  UsageByModelTable.swift
//  Xylem
//
//  Breakdown by model, mirroring Opcode's dashboard layout.
//

import SwiftUI

struct UsageByModelTable: View {
    let rows: [ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage by Model")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)

            if rows.isEmpty {
                Text("No usage data in this range")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ModelRow(row: row)
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

private struct ModelRow: View {
    let row: ModelUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(ModelNameFormatter.display(row.model))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("\(UsageFormatting.integer(row.sessionCount)) sessions")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                    if row.hasEstimatedCost == true {
                        EstimatedBadge()
                    }
                }
                HStack(spacing: 16) {
                    metric(label: "Input", value: UsageFormatting.compactTokens(row.inputTokens))
                    metric(label: "Output", value: UsageFormatting.compactTokens(row.outputTokens))
                    metric(label: "Cache W", value: UsageFormatting.compactTokens(row.cacheWriteTokens))
                    metric(label: "Cache R", value: UsageFormatting.compactTokens(row.cacheReadTokens))
                }
            }
            Spacer()
            Text(UsageFormatting.money(row.totalCostUSD))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(.vertical, 10)
    }

    private func metric(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }
}

/// "estimated" tag on a row whose cost uses a fallback rate: Xylem has no
/// price for that model yet, so it is priced like its family's current one.
private struct EstimatedBadge: View {
    var body: some View {
        Text("estimated")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(AppTheme.Colors.panelBorder))
            .help("Xylem has no price for this model yet, so it is priced like the newest model of its family.")
    }
}
