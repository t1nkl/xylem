//
//  GitTabView.swift
//  Xylem
//
//  Sidebar Git panel: current branch header plus collapsible sections for
//  worktrees, uncommitted changes, branches, remotes, and recent commits.
//  Styled like the Claude tab (headers with muted counts, 13pt rows,
//  muted meta). All interaction is surfaced through closures so
//  the view stays presentational.
//

import SwiftUI
import AppKit

struct GitTabView: View {
    let status: GitStatus?
    let directory: String?
    let isLoading: Bool
    var onRefresh: () -> Void = {}
    var onRunInActiveTab: (String) -> Void = { _ in }
    var onNewWorktree: () -> Void = {}
    var onOpenWorktree: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if status == nil {
                    emptyState
                } else if let status {
                    worktreesSection(status: status)
                    changesSection(status: status)
                    branchesSection(status: status)
                    remotesSection(status: status)
                    commitsSection(status: status)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.branch")
                .font(.system(size: AppTheme.Icons.button))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(status?.branch ?? "-")
                .font(AppTheme.Fonts.sectionItem)
                .foregroundStyle(AppTheme.Colors.panelText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.Icons.inline))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    // See RightSidebarView's refresh button: a repeatForever
                    // animation keyed on the flag never stopped.
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isLoading)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .help("Refresh git state")
        }
        .padding(.leading, SidebarLayout.gutter)
        .padding(.trailing, SidebarLayout.headerTrailing)
        .frame(height: SidebarLayout.headerHeight)
        .help(directory ?? "")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(directory == nil ? "No directory" : "Not a git repository")
                .font(AppTheme.Fonts.sectionItem)
                .foregroundStyle(AppTheme.Colors.textMuted)
            if directory != nil {
                Button("Initialize Repository") {
                    onRunInActiveTab("git init")
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Colors.accent)
            }
        }
        .padding(.horizontal, SidebarLayout.gutter)
        .padding(.vertical, 6)
    }

    // MARK: - Sections

    private func worktreesSection(status: GitStatus) -> some View {
        SidebarSection(
            title: "Worktrees",
            count: status.worktrees.count,
            // Typing `git worktree add` into the tab used to land in Claude's
            // prompt when claude was running there.
            trailingAction: .plus(
                tooltip: "New worktree tab - a branch in its own checkout, with its own Claude",
                action: onNewWorktree
            )
        ) {
            ForEach(status.worktrees) { worktree in
                SidebarRow(height: SidebarLayout.compactRowHeight, isInteractive: !worktree.isCurrent) {
                    Image(systemName: "folder")
                        .font(.system(size: AppTheme.Icons.button))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .padding(.trailing, 8)
                    Text(worktree.branch ?? worktree.displayName)
                        .font(AppTheme.Fonts.sectionItem)
                        .foregroundStyle(AppTheme.Colors.panelText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if worktree.isCurrent {
                        Circle().fill(AppTheme.Colors.statusGreen).frame(width: 6, height: 6)
                    }
                }
                .help(worktree.isCurrent ? worktree.path : "Open in a tab - \(worktree.path)")
                // Another checkout of this repository: open it in its tab
                // (or a new one), like a project from Directories.
                .onTapGesture { if !worktree.isCurrent { onOpenWorktree(worktree.path) } }
                .contextMenu {
                    if !worktree.isCurrent {
                        Button("Open in Tab") { onOpenWorktree(worktree.path) }
                    }
                    Button("Copy Path") { SidebarClipboard.copy(worktree.path) }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: worktree.path)
                    }
                }
            }
            if status.worktrees.isEmpty {
                Text("No worktrees")
                    .font(AppTheme.Fonts.sectionItem)
                    .foregroundStyle(AppTheme.Colors.textMuted)
                    .padding(.horizontal, SidebarLayout.gutter)
                    .padding(.vertical, 6)
            }
        }
    }

    private func changesSection(status: GitStatus) -> some View {
        let total = status.modified + status.untracked
        return SidebarSection(title: "Changes", count: total > 0 ? total : nil) {
            row(label: "Modified", value: "\(status.modified)")
            row(label: "Untracked", value: "\(status.untracked)")
            row(label: "Ahead", value: "\(status.ahead)")
            row(label: "Behind", value: "\(status.behind)")
        }
    }

    private func branchesSection(status: GitStatus) -> some View {
        SidebarSection(title: "Branches", count: status.branches.count) {
            ForEach(status.branches) { branch in
                SidebarRow(height: SidebarLayout.compactRowHeight) {
                    Image(systemName: branch.isCurrent ? "circle.fill" : "circle")
                        .font(.system(size: 6))
                        .foregroundStyle(branch.isCurrent ? AppTheme.Colors.statusGreen : AppTheme.Colors.textMuted)
                        .padding(.trailing, 8)
                    Text(branch.name)
                        .font(AppTheme.Fonts.sectionItem)
                        .foregroundStyle(AppTheme.Colors.panelText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let upstream = branch.upstream {
                        Text(upstream)
                            .font(AppTheme.Fonts.sectionMeta)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .contextMenu {
                    Button("Checkout") { onRunInActiveTab("git checkout " + TerminalSession.shellWord(branch.name)) }
                    Button("Copy Name") { copyToPasteboard(branch.name) }
                }
            }
        }
    }

    private func remotesSection(status: GitStatus) -> some View {
        SidebarSection(title: "Remotes", count: status.remotes.count) {
            ForEach(status.remotes) { remote in
                SidebarRow(height: 40, isInteractive: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remote.name)
                            .font(AppTheme.Fonts.sectionItem)
                            .foregroundStyle(AppTheme.Colors.panelText)
                        Text(remote.url)
                            .font(AppTheme.Fonts.sectionMeta)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .help(remote.url)
            }
        }
    }

    private func commitsSection(status: GitStatus) -> some View {
        SidebarSection(title: "Commits", count: status.recentCommits.count) {
            ForEach(status.recentCommits) { commit in
                SidebarRow(height: 40) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(commit.id)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(AppTheme.Colors.accent)
                            Text(commit.subject)
                                .font(AppTheme.Fonts.sectionItem)
                                .foregroundStyle(AppTheme.Colors.panelText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        HStack(spacing: 4) {
                            Text(commit.author)
                            Text("·")
                            Text(commit.relativeDate)
                        }
                        .font(AppTheme.Fonts.sectionMeta)
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .help(commit.subject)
                .contextMenu {
                    Button("Copy SHA") { copyToPasteboard(commit.id) }
                    Button("Show Diff") { onRunInActiveTab("git show " + TerminalSession.shellWord(commit.id)) }
                }
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        SidebarRow(height: SidebarLayout.compactRowHeight, isInteractive: false) {
            Text(label)
                .font(AppTheme.Fonts.sectionItem)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(AppTheme.Fonts.sectionItem)
                .foregroundStyle(AppTheme.Colors.panelText)
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }
}
