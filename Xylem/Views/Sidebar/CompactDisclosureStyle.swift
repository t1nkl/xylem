//
//  CompactDisclosureStyle.swift
//  Xylem
//
//  Small DisclosureGroup style used by nested groups inside right-panel
//  sections (plugin skills, agent teams). Same muted chevron and row pitch
//  as the panel so a sub-group header doesn't compete with its section.
//

import SwiftUI

struct CompactDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                SidebarRow(height: SidebarLayout.compactRowHeight) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.Icons.micro, weight: .medium))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .frame(width: 13, alignment: .leading)
                    configuration.label
                }
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    configuration.content
                }
                .padding(.leading, 13)
            }
        }
    }
}
