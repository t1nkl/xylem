//
//  OnboardingSheet.swift
//  Xylem
//
//  First-launch welcome. Explains what Xylem adds on top of running
//  `claude` in a terminal (cost tracking, session jumping, config
//  visibility) and invites the user to pick a first folder. Shown once,
//  gated by `AppSettings.Keys.welcomed` - existing installs with a prior
//  tabs-state file get auto-migrated to welcomed=true in ContentView so
//  this never surfaces to returning users.
//

import SwiftUI
import AppKit

struct OnboardingSheet: View {
    var mostRecentSession: ClaudeSession? = nil
    var onOpenFolder: (String) -> Void = { _ in }
    var onResumeSession: (ClaudeSession) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.top, 24)
                .padding(.bottom, 22)
            Divider().background(AppTheme.Colors.panelBorder)
            features
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            Divider().background(AppTheme.Colors.panelBorder)
            footer
                .padding(24)
        }
        .frame(width: 520)
        .background(AppTheme.Colors.panelBackground)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 10) {
            XylemMark(size: 32, color: AppTheme.Colors.accent)
                .padding(.bottom, 4)
            Text("Welcome to Xylem")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text("Claude Code with memory of your projects.")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: - Features

    private var features: some View {
        VStack(spacing: 14) {
            featureRow(
                icon: "chart.bar",
                title: "Cost you can actually see",
                body: "Per-session, per-project, per-model - Usage dashboard (⌘U)."
            )
            featureRow(
                icon: "clock.arrow.circlepath",
                title: "Pick up where you left off",
                body: "Past Claude sessions in the sidebar - one click resumes."
            )
            featureRow(
                icon: "gearshape.2",
                title: "Know what config Claude is using",
                body: "Skills, plugins, MCP, hooks, permissions - merged across scopes."
            )
        }
    }

    private func featureRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                Text("Explore first")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if let session = mostRecentSession {
                Button {
                    onResumeSession(session)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text("Resume \(Self.resumeLabel(for: session))")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(AppTheme.Colors.surfaceHover)
                    )
                }
                .buttonStyle(.plain)
                .help("Resume your most recent Claude session, in \(session.projectPath)")
            }

            Button(action: pickFolder) {
                Text("Open a Folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(AppTheme.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// The project's folder name, not the session's first prompt: the
    /// prompt is the user's own text (often another language, e.g. Cyrillic
    /// in an English UI) and was cut mid-sentence. The
    /// tooltip gives the project's path.
    static func resumeLabel(for session: ClaudeSession) -> String {
        let name = (session.projectPath as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "/" else { return "last session" }
        return name.count > 24 ? String(name.prefix(22)) + "…" : name
    }

    private func pickFolder() {
        guard let url = OpenPanels.pick(.projectFolder) else { return }
        onOpenFolder(url.path)
    }
}
