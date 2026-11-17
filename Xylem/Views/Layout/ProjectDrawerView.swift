//
//  ProjectDrawerView.swift
//  Xylem
//
//  The drawer over the terminal (mock-up C of three, 2026-11-16):
//  Files = the project tree on top, the selected file's text below;
//  Changes = git's changed files on top, the selected file's diff below.
//  The terminal keeps its size underneath (no SIGWINCH while browsing).
//

import SwiftUI
import AppKit

struct ProjectDrawerActions {
    /// Types a path (shell-quoted) into the active tab's Claude, no Enter.
    var insertPath: (String) -> Void = { _ in }
    /// Opens a file in the app picked in Settings (or the system default).
    var openFile: (String) -> Void = { _ in }
    var revealInFinder: (String) -> Void = { _ in }
    /// The picked app's name for labels; nil = the system default.
    var openerName: () -> String? = { nil }
}

struct ProjectDrawerView: View {
    let model: ProjectDrawerModel
    var actions = ProjectDrawerActions()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Colors.panelBorder)
            switch model.mode {
            case .files: FilesContent(model: model, actions: actions)
            case .changes: ChangesContent(model: model, actions: actions)
            case nil: EmptyView()
            }
        }
        .background(AppTheme.Colors.panelBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.black.opacity(0.55)).frame(width: 1)
        }
        // A cheap edge shade instead of a blurred shadow, which is costly to
        // render on a view this size.
        .background(alignment: .leading) {
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
                .offset(x: -14)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.mode == .files ? "folder" : "plusminus")
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(model.mode == .files ? "Files" : "Changes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            if let directory = model.directory {
                Text(DrawerFormat.shortPath(directory))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { model.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .hoverHighlight()
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

// MARK: - Files

private struct FilesContent: View {
    let model: ProjectDrawerModel
    let actions: ProjectDrawerActions

    var body: some View {
        // Two views, each reading only its own model properties: a colour
        // update of the preview doesn't rebuild the tree, and the other way.
        VSplitView {
            FileTreePane(model: model, actions: actions)
                .frame(minHeight: 120, idealHeight: 260)
            FilePreviewContainer(model: model, actions: actions)
                .frame(minHeight: 120)
        }
    }
}

private struct FilePreviewContainer: View {
    let model: ProjectDrawerModel
    let actions: ProjectDrawerActions
    var body: some View {
        FilePreviewPane(path: model.selectedFile, preview: model.preview, colours: model.previewColours, actions: actions)
    }
}

private struct FileTreePane: View {
    let model: ProjectDrawerModel
    let actions: ProjectDrawerActions

    var body: some View { tree }

    @ViewBuilder
    private var tree: some View {
        if model.directory == nil {
            DrawerEmpty(icon: "folder", message: "Open a project in this tab to browse its files.")
        } else {
            let kinds = model.changeKinds
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.visibleRows, id: \.entry.id) { row in
                        FileRow(
                            entry: row.entry,
                            depth: row.depth,
                            isExpanded: model.expanded.contains(row.entry.path),
                            isSelected: model.selectedFile == row.entry.path,
                            change: kinds[row.entry.path],
                            onTap: {
                                if row.entry.isDirectory { model.toggleFolder(row.entry.path) } else { model.selectFile(row.entry.path) }
                            },
                            actions: actions
                        )
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct FileRow: View {
    let entry: ProjectFileEntry
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let change: GitFileChange.Kind?
    let onTap: () -> Void
    let actions: ProjectDrawerActions
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Group {
                    if entry.isDirectory {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(AppTheme.Colors.textMuted)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.isDirectory ? AppTheme.Colors.statusBlue.opacity(0.85) : AppTheme.Colors.textSecondary)
                    .frame(width: 14)
                Text(entry.name)
                    .font(.system(size: 13))
                    .foregroundStyle(change.map { DrawerFormat.color($0) } ?? AppTheme.Colors.textPrimary)
                    .strikethrough(change == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let change {
                    Text(change.letter)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DrawerFormat.color(change))
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 4)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.path)
        // Drag onto the terminal to type its path (XylemTerminalView).
        .onDrag { NSItemProvider(object: URL(fileURLWithPath: entry.path) as NSURL) }
        .contextMenu { PathMenu(path: entry.path, isDirectory: entry.isDirectory, actions: actions) }
    }
}

private struct FilePreviewPane: View {
    let path: String?
    let preview: FilePreview?
    let colours: [[SyntaxRun]]?
    let actions: ProjectDrawerActions

    var body: some View {
        VStack(spacing: 0) {
            if let path {
                PaneHeader(title: (path as NSString).lastPathComponent, subtitle: nil, path: path, actions: actions)
                switch preview {
                case .text(let lines, let truncated)?:
                    CodeLines(lines: lines, colours: colours, footer: truncated ? "Only the first 1 MB is shown." : nil)
                case .binary?:
                    DrawerEmpty(icon: "doc", message: "Not a text file.", cta: ("Open", { actions.openFile(path) }))
                case .unreadable?:
                    DrawerEmpty(icon: "lock", message: "Can't read this file.")
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DrawerEmpty(icon: "doc.text", message: "Pick a file to see its contents.")
            }
        }
        .background(AppTheme.Colors.terminalBackground)
    }
}

/// A read-only file: line numbers + monospaced text, scrolls both ways,
/// selectable across lines (`CodeTextView`).
private struct CodeLines: View {
    let lines: [String]
    /// One entry per line once highlighting is done; plain text until then.
    var colours: [[SyntaxRun]]?
    var footer: String?

    var body: some View {
        let width = CGFloat(String(lines.count).count) * 7.5 + 14
        var shown = lines.enumerated().map { index, line in
            CodeTextLine(text: line, runs: colours?[safe: index], gutter: ["\(index + 1)"])
        }
        if let footer { shown.append(CodeTextLine(text: footer, kind: .note)) }
        return CodeTextView(lines: shown, columns: [CodeGutterColumn(width: width - 10)])
    }
}

// MARK: - Changes

private struct ChangesContent: View {
    let model: ProjectDrawerModel
    let actions: ProjectDrawerActions

    var body: some View {
        VSplitView {
            ChangeListPane(model: model, actions: actions)
                .frame(minHeight: 110, idealHeight: 220)
            DiffPaneContainer(model: model, actions: actions)
                .frame(minHeight: 140)
        }
    }
}

private struct DiffPaneContainer: View {
    let model: ProjectDrawerModel
    let actions: ProjectDrawerActions
    var body: some View {
        DiffPane(change: model.selectedChange, root: model.changes?.root, diff: model.diff, colours: model.diffColours, actions: actions)
    }
}

private struct ChangeListPane: View {
    let model: ProjectDrawerModel
    let actions: ProjectDrawerActions

    var body: some View { list }

    @ViewBuilder
    private var list: some View {
        if model.directory == nil {
            DrawerEmpty(icon: "plusminus", message: "Open a project in this tab to see its changes.")
        } else if !model.changesLoaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = model.changes {
            if snapshot.changes.isEmpty {
                DrawerEmpty(icon: "checkmark.circle", message: "No changes. The working tree matches the last commit.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack {
                            Text("\(snapshot.changes.count) changed file\(snapshot.changes.count == 1 ? "" : "s")")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.textMuted)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        ForEach(model.changeRows) { row in
                            switch row {
                            case .folder(let path, let label, let depth, let count):
                                ChangeFolderRow(label: label, depth: depth, fileCount: count,
                                                isExpanded: !model.collapsedChangeFolders.contains(path),
                                                onTap: { model.toggleChangeFolder(path) })
                            case .file(let change, let depth):
                                ChangeRow(change: change, depth: depth, root: snapshot.root,
                                          isSelected: model.selectedChange?.path == change.path,
                                          onTap: { model.selectChange(change) }, actions: actions)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        } else {
            DrawerEmpty(icon: "arrow.triangle.branch", message: "This folder isn't a git repository.")
        }
    }
}

private struct ChangeFolderRow: View {
    let label: String
    let depth: Int
    let fileCount: Int
    let isExpanded: Bool
    let onTap: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.statusBlue.opacity(0.85))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(fileCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textMuted)
            }
            .padding(.leading, CGFloat(depth) * 14 + 4)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(isHovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ChangeRow: View {
    let change: GitFileChange
    var depth = 0
    let root: String
    let isSelected: Bool
    let onTap: () -> Void
    let actions: ProjectDrawerActions
    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Spacer().frame(width: 10)   // the folders' chevron column
                Text(change.kind.letter)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(DrawerFormat.color(change.kind))
                    .frame(width: 14)
                Text(change.name)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .strikethrough(change.kind == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let old = change.oldPath {
                    Text("← \((old as NSString).lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .lineLimit(1)
                        .help("Renamed from \(old)")
                }
                Spacer(minLength: 4)
                DiffCounts(additions: change.additions, deletions: change.deletions, isBinary: change.isBinary)
            }
            .padding(.leading, CGFloat(depth) * 14 + 4)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(change.path)
        .onDrag { NSItemProvider(object: URL(fileURLWithPath: (root as NSString).appendingPathComponent(change.path)) as NSURL) }
        .contextMenu {
            PathMenu(path: (root as NSString).appendingPathComponent(change.path), isDirectory: false, actions: actions)
        }
    }
}

private struct DiffCounts: View {
    let additions: Int?
    let deletions: Int?
    let isBinary: Bool
    var body: some View {
        HStack(spacing: 4) {
            if let additions, additions > 0 { Text("+\(additions)").foregroundStyle(AppTheme.Colors.statusGreen) }
            if let deletions, deletions > 0 { Text("-\(deletions)").foregroundStyle(AppTheme.Colors.statusRed) }
            // Unknown counts (a very large new file) show nothing, not "bin".
            if isBinary { Text("bin").foregroundStyle(AppTheme.Colors.textMuted) }
        }
        .font(.system(size: 11, design: .monospaced))
    }
}

private struct DiffPane: View {
    let change: GitFileChange?
    let root: String?
    let diff: DiffDocument?
    let colours: [Int: [SyntaxRun]]?
    let actions: ProjectDrawerActions

    var body: some View {
        VStack(spacing: 0) {
            if let change, let root {
                let path = (root as NSString).appendingPathComponent(change.path)
                PaneHeader(title: change.path, subtitle: change.kind.letter, path: path, actions: actions, isDeleted: change.kind == .deleted)
                if let diff {
                    if diff.isBinary {
                        DrawerEmpty(icon: "doc", message: "Binary file changed.")
                    } else if diff.lines.isEmpty {
                        DrawerEmpty(icon: "equal", message: change.oldPath.map { "Renamed from \($0). The content didn't change." }
                                    ?? "No changes to the text (only the file's mode, or an empty file).")
                    } else {
                        DiffLines(document: diff, colours: colours)
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                DrawerEmpty(icon: "plusminus", message: "Pick a file to see its diff.")
            }
        }
        .background(AppTheme.Colors.terminalBackground)
    }
}

private struct DiffLines: View {
    let document: DiffDocument
    var colours: [Int: [SyntaxRun]]?

    var body: some View {
        let numbers = document.lines.compactMap { $0.newNumber ?? $0.oldNumber }.max() ?? 1
        let width = CGFloat(String(numbers).count) * 7.5 + 10
        var shown = document.lines.map { line in
            CodeTextLine(
                text: line.text,
                runs: line.kind == .hunk || line.kind == .note ? nil : colours?[line.id],
                kind: Self.kind(line.kind),
                gutter: [line.oldNumber.map(String.init) ?? "", line.newNumber.map(String.init) ?? "", Self.marker(line.kind)]
            )
        }
        if document.isTruncated {
            shown.append(CodeTextLine(text: "The diff is longer than \(UnifiedDiffParser.maxLines) lines; the rest isn't shown.", kind: .note))
        }
        return CodeTextView(lines: shown, columns: [
            CodeGutterColumn(width: width),
            CodeGutterColumn(width: width),
            CodeGutterColumn(width: 18, alignment: .center, colouredByKind: true)
        ])
    }

    private static func kind(_ kind: DiffLine.Kind) -> CodeTextLine.Kind {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .hunk: .hunk
        case .note: .note
        case .context: .plain
        }
    }

    private static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind { case .added: "+"; case .removed: "-"; default: "" }
    }
}

// MARK: - Shared

/// One line of code: plain until its colours arrive.
private struct SyntaxLine: View {
    let text: String
    let runs: [SyntaxRun]?

    var body: some View {
        if let runs, !runs.isEmpty {
            Text(SyntaxPalette.attributed(runs))
        } else {
            Text(text.isEmpty ? " " : text).foregroundStyle(AppTheme.Colors.textPrimary)
        }
    }
}

/// Colours for code on the terminal's dark background (GitHub Dark tones).
enum SyntaxPalette {
    static func attributed(_ runs: [SyntaxRun]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece.foregroundColor = color(run.scope)
            if run.scope == .comment { piece.inlinePresentationIntent = .emphasized }
            if run.scope == .heading { piece.inlinePresentationIntent = .stronglyEmphasized }
            result.append(piece)
        }
        return result
    }

    static func color(_ scope: SyntaxScope?) -> Color {
        switch scope {
        case .keyword: Color(red: 1.00, green: 0.48, blue: 0.45)      // #FF7B72
        case .string: Color(red: 0.65, green: 0.84, blue: 1.00)       // #A5D6FF
        case .number: Color(red: 0.47, green: 0.75, blue: 1.00)       // #79C0FF
        case .comment: Color(red: 0.55, green: 0.58, blue: 0.62)      // #8B949E
        case .function: Color(red: 0.82, green: 0.66, blue: 1.00)     // #D2A8FF
        case .type: Color(red: 1.00, green: 0.65, blue: 0.34)         // #FFA657
        case .property, .variable: Color(red: 0.47, green: 0.75, blue: 1.00)
        case .tag: Color(red: 0.49, green: 0.91, blue: 0.53)          // #7EE787
        case .meta: Color(red: 0.55, green: 0.58, blue: 0.62)
        case .heading: Color(red: 0.47, green: 0.75, blue: 1.00)     // #79C0FF, bold
        case nil: AppTheme.Colors.textPrimary
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct PaneHeader: View {
    let title: String
    let subtitle: String?
    let path: String
    let actions: ProjectDrawerActions
    var isDeleted = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !isDeleted {
                Button("Open") { actions.openFile(path) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .hoverHighlight()
                    .help("Open in \(actions.openerName() ?? "its default app")")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(AppTheme.Colors.panelBackgroundRaised.opacity(0.6))
    }
}

private struct PathMenu: View {
    let path: String
    let isDirectory: Bool
    let actions: ProjectDrawerActions

    var body: some View {
        Button("Insert Path in Claude") { actions.insertPath(path) }
        if !isDirectory {
            Button("Open in \(actions.openerName() ?? "Default App")") { actions.openFile(path) }
        }
        Button("Reveal in Finder") { actions.revealInFinder(path) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

private struct DrawerEmpty: View {
    let icon: String
    let message: String
    var cta: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(AppTheme.Colors.textMuted)
            Text(message).font(.system(size: 12)).foregroundStyle(AppTheme.Colors.textSecondary).multilineTextAlignment(.center)
            if let cta {
                Button(cta.0, action: cta.1).buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum DrawerFormat {
    static func color(_ kind: GitFileChange.Kind) -> Color {
        switch kind {
        case .modified, .renamed: AppTheme.Colors.statusAmber
        case .added, .untracked: AppTheme.Colors.statusGreen
        case .deleted, .conflicted: AppTheme.Colors.statusRed
        }
    }

    static func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
