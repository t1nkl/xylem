//
//  ShowMoreButton.swift
//  Xylem
//
//  Reusable "Show more / less" trigger used to keep sidebar lists compact by
//  default. Label and icon swap automatically when expanded. Muted, on the
//  same row pitch as the list it ends.
//

import SwiftUI

struct ShowMoreButton: View {
    let isExpanded: Bool
    let remaining: Int
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            SidebarRow {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: AppTheme.Icons.micro, weight: .medium))
                    .frame(width: 14, alignment: .leading)
                Text(isExpanded ? "Show less" : "Show \(remaining) more")
                    .font(AppTheme.Fonts.sectionMeta)
                Spacer(minLength: 0)
            }
            .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show less" : "Show \(remaining) more")
    }
}
