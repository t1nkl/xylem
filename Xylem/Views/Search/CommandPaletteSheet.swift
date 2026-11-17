//
//  CommandPaletteSheet.swift
//  Xylem
//
//  Global ⌘K palette: every frequent user action (split, focus, open sheets,
//  refresh) registered as a PaletteCommand. Filtered by substring + keyword
//  matches so the user can hop around without hunting through menus.
//
//  Below the commands, a "Prompts" section answers "where did I ask to do
//  X?": from 2 typed characters it lists past human prompts of every
//  session (PromptHistoryViewModel), newest first; Enter / click resumes
//  that session. One highlight index runs over both sections. The search
//  runs off the main actor per keystroke; results for a query the user has
//  already changed are dropped (the `.task(id:)` is cancelled).
//

import SwiftUI
import AppKit

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    let icon: String
    let shortcut: String?
    let run: () -> Void
}

/// Where the palette's "Prompts" section comes from and what picking a
/// prompt does.
struct PalettePromptSource {
    let history: PromptHistoryViewModel
    let open: (PromptHistoryEntry) -> Void
}

struct CommandPaletteSheet: View {
    let commands: [PaletteCommand]
    let prompts: PalettePromptSource?
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var highlight: Int = 0
    @State private var promptResults: [PromptHistoryEntry] = []
    @FocusState private var fieldFocused: Bool

    init(commands: [PaletteCommand], prompts: PalettePromptSource? = nil, onClose: @escaping () -> Void) {
        self.commands = commands
        self.prompts = prompts
        self.onClose = onClose
    }

    /// A palette row: a command or a past prompt. Prompt ids are prefixed,
    /// so they never collide with command ids.
    private enum Row: Identifiable {
        case command(PaletteCommand)
        case prompt(PromptHistoryEntry)

        var id: String {
            switch self {
            case .command(let command): command.id
            case .prompt(let entry): "prompt:" + entry.id
            }
        }
    }

    /// What the prompt search depends on: a refreshed snapshot runs the
    /// current query again.
    private struct PromptSearchKey: Equatable {
        let query: String
        let snapshot: ObjectIdentifier?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                TextField("Run command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($fieldFocused)
                    .onSubmit(activate)
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppTheme.Colors.panelBackground)
            .overlay(alignment: .bottom) {
                Rectangle().fill(AppTheme.Colors.panelBorder).frame(height: 0.5)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let commandCount = filtered.count
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index == commandCount { promptsHeader }
                            switch row {
                            case .command(let cmd):
                                self.row(cmd: cmd, highlighted: index == highlight)
                                    .onTapGesture { run(cmd) }
                            case .prompt(let entry):
                                promptRow(entry, highlighted: index == highlight)
                                    .onTapGesture { open(entry) }
                            }
                        }
                        if let status = promptStatus {
                            if commandCount > 0 { promptsHeader }
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        } else if rows.isEmpty {
                            Text("No matching commands")
                                .font(.system(size: 12))
                                .foregroundStyle(AppTheme.Colors.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlight) { _, index in
                    let rows = self.rows
                    guard rows.indices.contains(index) else { return }
                    proxy.scrollTo(rows[index].id)
                }
            }
        }
        .frame(width: 540, height: 420)
        .background(AppTheme.Colors.background)
        .onAppear {
            fieldFocused = true
            highlight = 0
            prompts?.history.refresh()
        }
        .onChange(of: query) { _, _ in highlight = 0 }
        .task(id: PromptSearchKey(query: query, snapshot: prompts?.history.snapshot.map(ObjectIdentifier.init))) {
            await searchPrompts()
        }
    }

    // MARK: - Filtering / selection

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return commands }
        return commands.filter { cmd in
            cmd.title.lowercased().contains(q)
                || (cmd.subtitle?.lowercased().contains(q) ?? false)
                || cmd.keywords.contains(where: { $0.lowercased().contains(q) })
        }
    }

    /// Commands first, then matching prompts - the order ↑↓ walks.
    private var rows: [Row] {
        filtered.map(Row.command) + promptResults.map(Row.prompt)
    }

    private var isPromptQuery: Bool {
        PromptHistoryIndexer.normalized(query).count >= PromptHistorySnapshot.minimumQueryLength
    }

    /// A line in place of prompt rows: still indexing, or nothing at all
    /// matched. nil when there are prompt rows or nothing to say.
    private var promptStatus: String? {
        guard let prompts, isPromptQuery, promptResults.isEmpty else { return nil }
        if prompts.history.snapshot == nil { return "Indexing past prompts…" }
        return filtered.isEmpty ? "No matching commands or prompts" : nil
    }

    private func searchPrompts() async {
        guard let snapshot = prompts?.history.snapshot, isPromptQuery else {
            if !promptResults.isEmpty { promptResults = [] }
            return
        }
        let results = await PromptHistoryViewModel.search(query, in: snapshot)
        // Cancelled when the query or the snapshot changed meanwhile.
        guard !Task.isCancelled, results != promptResults else { return }
        promptResults = results
    }

    private func moveHighlight(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        highlight = (highlight + delta + count) % count
    }

    private func activate() {
        let rows = self.rows
        guard rows.indices.contains(highlight) else { return }
        switch rows[highlight] {
        case .command(let cmd): run(cmd)
        case .prompt(let entry): open(entry)
        }
    }

    private func run(_ cmd: PaletteCommand) {
        cmd.run()
        onClose()
    }

    private func open(_ entry: PromptHistoryEntry) {
        prompts?.open(entry)
        onClose()
    }

    // MARK: - Rows

    private func row(cmd: PaletteCommand, highlighted: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if highlighted {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.Colors.accent.opacity(0.2))
                        .frame(width: 28, height: 24)
                }
                Image(systemName: cmd.icon)
                    .foregroundStyle(highlighted ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let subtitle = cmd.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                }
            }
            Spacer()
            if let shortcut = cmd.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(highlighted ? AppTheme.Colors.textSecondary : AppTheme.Colors.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            highlighted
                ? AppTheme.Colors.tabBackground
                : Color.clear
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: highlighted)
    }

    private var promptsHeader: some View {
        Text("Prompts")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// Snippet with the match in bold accent, then "project · 3 days ago".
    private func promptRow(_ entry: PromptHistoryEntry, highlighted: Bool) -> some View {
        let snippet = PromptHistorySnippet(text: entry.text, query: query)
        var text = AttributedString(snippet.before)
        var match = AttributedString(snippet.match)
        match.font = .system(size: 12, weight: .bold)
        match.foregroundColor = AppTheme.Colors.accent
        text.append(match)
        text.append(AttributedString(snippet.after))
        let date = entry.date.map { Self.relativeDate.localizedString(for: $0, relativeTo: .now) }
        let detail = [entry.projectName, date].compactMap { $0 }.joined(separator: " · ")

        return HStack(spacing: 12) {
            ZStack {
                if highlighted {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(AppTheme.Colors.accent.opacity(0.2))
                        .frame(width: 28, height: 24)
                }
                Image(systemName: "text.bubble")
                    .foregroundStyle(highlighted ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
            }
            .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(highlighted ? AppTheme.Colors.tabBackground : Color.clear)
        .contentShape(Rectangle())
        .help(entry.projectPath)
        .animation(.easeInOut(duration: 0.12), value: highlighted)
    }
}
