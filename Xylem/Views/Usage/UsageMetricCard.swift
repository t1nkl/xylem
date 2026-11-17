//
//  UsageMetricCard.swift
//  Xylem
//
//  Reusable top-of-dashboard metric tile. Pure presentational.
//

import SwiftUI

struct UsageMetricCard: View {
    let title: String
    let value: String
    /// Small muted line under the value (e.g. the subagents' share).
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
