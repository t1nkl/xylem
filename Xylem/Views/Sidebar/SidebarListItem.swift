//
//  SidebarListItem.swift
//  Xylem
//
//  Compact row used inside collapsible sections (skills, agents, MCP, …):
//  small accent dot, primary title, muted trailing detail. Interactive rows
//  get the panel's hover highlight.
//

import SwiftUI

struct SidebarListItem: View {
    let title: String
    var detail: String? = nil
    /// Status-style dot: keeps the status green, not the (darker) brand accent.
    var accent: Color = AppTheme.Colors.statusGreen
    var isInteractive: Bool = false

    var body: some View {
        SidebarRow(height: SidebarLayout.compactRowHeight, isInteractive: isInteractive) {
            Circle().fill(accent).frame(width: 5, height: 5)
                .padding(.trailing, 8)
            Text(title)
                .font(AppTheme.Fonts.sectionItem)
                .foregroundStyle(AppTheme.Colors.panelText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(AppTheme.Fonts.sectionMeta)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .help(tooltip)
    }

    /// Surface the full title + detail on hover so truncated rows stay
    /// legible even at narrow sidebar widths.
    private var tooltip: String {
        if let detail, !detail.isEmpty {
            return "\(title)\n\(detail)"
        }
        return title
    }
}
