//
//  ClaudeStatusBadge.swift
//  Xylem
//
//  Toolbar badge for status.claude.com. Invisible while everything is
//  operational; otherwise a coloured dot plus the most relevant incident's
//  name. Click opens a popover with every open incident and a link to the
//  status page. Presentational: the status value comes from the toolbar.
//

import SwiftUI
import AppKit

struct ClaudeStatusBadge: View {
    let status: ClaudeServiceStatus?

    @State private var showsDetails = false

    var body: some View {
        if let status, !status.isAllClear, let headline = status.headline {
            Button { showsDetails.toggle() } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.color(status.level, affectsClaudeCode: headline.affectsClaudeCode))
                        .frame(width: 7, height: 7)
                    Text(headline.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if status.incidents.count > 1 {
                        Text("+\(status.incidents.count - 1)")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 300)
                // Room between the text and the capsule's rounded ends,
                // like the context and model items.
                .padding(.horizontal, 10)
            }
            .help("Claude status: \(status.summary)")
            .accessibilityLabel("Claude status: \(headline.name)")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                ClaudeStatusDetails(status: status)
            }
        }
    }

    /// Red for outages, amber for partial / degraded, blue for maintenance.
    /// Incidents that don't touch Claude Code stay muted.
    static func color(_ level: ClaudeServiceStatus.Level, affectsClaudeCode: Bool) -> Color {
        guard affectsClaudeCode else { return AppTheme.Colors.textMuted }
        switch level {
        case .majorOutage: return AppTheme.Colors.statusRed
        case .partialOutage, .degraded: return AppTheme.Colors.statusAmber
        case .maintenance: return AppTheme.Colors.statusBlue
        case .operational: return AppTheme.Colors.textMuted
        }
    }
}

private struct ClaudeStatusDetails: View {
    let status: ClaudeServiceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(status.summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            ForEach(status.incidents) { incident in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(ClaudeStatusBadge.color(incident.level, affectsClaudeCode: incident.affectsClaudeCode))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        // Own sizes, independent of the right panel's tokens.
                        Text(incident.name)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(([incident.status.capitalized] + incident.components).joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if let link = incident.link {
                        Button {
                            NSWorkspace.shared.open(link)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .help("Open this incident")
                        .accessibilityLabel("Open incident \(incident.name)")
                    }
                }
            }
            Button("Open status.claude.com") {
                NSWorkspace.shared.open(ClaudeServiceStatus.pageURL)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }
}
