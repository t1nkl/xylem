//
//  UpdateReadyBadge.swift
//  Xylem
//
//  "New update available" in the window toolbar while a downloaded update
//  waits to install on quit, placed before the context and model capsule.
//  A single macOS notification is easy to miss, and Xylem stays open for
//  days. A click
//  opens Sparkle's window: Install and Relaunch / Install on Quit.
//

import SwiftUI

struct UpdateReadyBadge: View {
    let version: String
    let onShow: () -> Void

    /// The system's toolbar capsules are 24 pt (measured on a screenshot:
    /// 48 px at 2x); 28 and 30 read taller than their neighbours.
    static let height: CGFloat = 24

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                // No pulse: on the toolbar glass even a periodic one keeps
                // Core Animation busy at 15-30% CPU.
                Image(systemName: "arrow.down.circle")
                Text("New update available")
                    .lineLimit(1)
            }
            .foregroundStyle(AppTheme.Colors.accent)
            // Room before the capsule's rounded ends, like the other items.
            .padding(.horizontal, 10)
        }
        .help("Xylem \(version) is downloaded and installs when you quit. Click to install it now.")
        .accessibilityLabel("New update available: Xylem \(version)")
    }
}
