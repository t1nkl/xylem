//
//  SessionsListView.swift
//  Xylem
//
//  Compact list of recent Claude Code sessions: green
//  dot, title, right-aligned relative time. Title comes from the first user
//  message of each .jsonl. Each row is interactive with a context menu.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SessionsListView: View {
    let sessions: [ClaudeSession]
    var onSelect: (ClaudeSession) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                SessionRow(session: session, onSelect: { onSelect(session) })
            }

            if sessions.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    message: "No previous sessions yet."
                )
            }
        }
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            SidebarRow {
                Circle()
                    .fill(AppTheme.Colors.statusGreen)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 8)
                Text(session.title)
                    .font(AppTheme.Fonts.sectionItem)
                    .foregroundStyle(AppTheme.Colors.panelText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 10)
                RelativeTimeText(date: session.lastModified)
                    .font(AppTheme.Fonts.sectionMeta)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .buttonStyle(.plain)
        // The whole first prompt (the row shows its 60-character cut).
        .help("\(session.firstPrompt ?? session.title)\n\n\(session.projectPath)")
        .accessibilityLabel(session.title)
        .contextMenu {
            Button("Resume Session") { onSelect() }
            Divider()
            Button("Export as Markdown…") { exportMarkdown() }
            Divider()
            Button("Copy Session ID") { copyToPasteboard(session.id) }
            Button("Copy Title") { copyToPasteboard(session.title) }
            Button("Reveal Transcript in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        // `UTType(filenameExtension:)` can return nil for rare extensions -
        // explicit fallback keeps the picker working even if the system
        // hasn't registered a .md mapping.
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.suggestedFilename(for: session)
        panel.title = "Export Session Transcript"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Run the parse off-main so exporting long transcripts doesn't stall
        // the sidebar button (the save panel has already dismissed by now).
        let session = session
        Task.detached(priority: .userInitiated) {
            let exporter = SessionExporter()
            let markdown = exporter.exportMarkdown(for: session)
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func suggestedFilename(for session: ClaudeSession) -> String {
        let project = (session.projectPath as NSString).lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let date = formatter.string(from: session.lastModified)
        let base = project.isEmpty ? session.id : project
        return "\(base)-\(date).md"
    }
}
