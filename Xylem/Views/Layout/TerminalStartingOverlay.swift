//
//  TerminalStartingOverlay.swift
//  Xylem
//
//  The loader over a terminal that is still starting: a small spinner and "Starting Claude Code…" on the
//  terminal background, until claude draws its first screen
//  (`TerminalSession.isStarting`). It goes at once, no fade, and covers the
//  user's shell start-up output on the way.
//

import SwiftUI

struct TerminalStartingOverlay: View {
    let session: TerminalSession

    var body: some View {
        // Also before `start()`: a restored tab checks first whether its
        // conversation is open elsewhere.
        if session.isStarting || !session.isStarted {
            ZStack {
                Color(nsColor: TerminalAppearance.background)
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(session.launchedClaude ? "Starting Claude Code…" : "Starting…")
                        .font(AppTheme.Fonts.sectionMeta)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }
}
