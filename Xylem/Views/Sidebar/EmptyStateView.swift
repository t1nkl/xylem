//
//  EmptyStateView.swift
//  Xylem
//
//  Unified empty-state block for sidebar sections. A single icon + message
//  line with an optional accent-coloured CTA button below. Replaces the
//  mix of bare `Text("No X")` lines so tone and spacing stay consistent
//  across every section.
//

import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let message: String
    var cta: CTA? = nil

    struct CTA {
        let label: String
        let action: () -> Void
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.Icons.inline))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(message)
                    .font(AppTheme.Fonts.sectionItem)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if let cta {
                    Button(cta.label, action: cta.action)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .padding(.horizontal, SidebarLayout.gutter)
        .padding(.vertical, 6)
    }
}
