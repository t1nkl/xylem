//
//  SkillsDirectorySheet.swift
//  Xylem
//
//  Sheet that lists every skill published on skills.sh. Supports search,
//  sort-by-installs (default), and groups by repository. "Install" copies
//  or runs the `npx skills add <source>/<skillId>` command in the active
//  terminal tab.
//
//  The filtered / grouped lists come pre-computed from the view model and
//  every list is lazy; the "updated Xm ago" text ticks in its own
//  TimelineView leaf so the sheet body isn't re-run on a clock.
//

import SwiftUI
import AppKit

struct SkillsDirectorySheet: View {
    @State var viewModel = SkillsDirectoryViewModel()
    @Environment(\.dismiss) private var dismiss

    var onInstall: (MarketplaceSkill) -> Void = { _ in }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                header
                searchBar
                divider
                listContent
            }
            .padding(20)
            .opacity(shouldDim ? 0.3 : 1)
            .allowsHitTesting(!shouldDim)

            if viewModel.isRefreshing && viewModel.skills.isEmpty {
                loadingCard
            }
        }
        .background(AppTheme.Colors.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 760, minHeight: 620)
        .task { await viewModel.loadInitial() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Skills Directory")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                subtitle
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            groupToggle
            refreshButton
            closeButton
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let error = viewModel.lastError {
            Text(error)
        } else if let updated = viewModel.lastUpdated {
            RelativeTimeText(prefix: "\(viewModel.skills.count) skills · updated ", date: updated)
        } else if viewModel.isRefreshing {
            Text("Fetching skills.sh catalogue…")
        } else {
            Text("Discover and install skills for AI agents")
        }
    }

    private var groupToggle: some View {
        Button {
            viewModel.groupByRepo.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.groupByRepo ? "rectangle.stack.fill" : "list.bullet")
                    .font(.system(size: 10))
                Text(viewModel.groupByRepo ? "By Repo" : "By Popularity")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Colors.tabBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var refreshButton: some View {
        Button {
            Task { await viewModel.refresh() }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small).tint(AppTheme.Colors.textSecondary)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                Text(viewModel.isRefreshing ? "Refreshing" : "Refresh")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.Colors.tabBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRefreshing)
    }

    private var closeButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .padding(6)
                .background(Circle().fill(AppTheme.Colors.panelBackground))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.textMuted)
            TextField("Search skills, repos, or keywords", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.textPrimary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.Colors.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
        )
    }

    private var divider: some View {
        Rectangle().fill(AppTheme.Colors.panelBorder).frame(height: 0.5)
    }

    // MARK: - List

    @ViewBuilder
    private var listContent: some View {
        if viewModel.groupByRepo {
            groupedList
        } else {
            flatList
        }
    }

    private var flatList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(viewModel.filteredSkills) { skill in
                    SkillRow(skill: skill, onInstall: { onInstall(skill) })
                }
                if viewModel.filteredSkills.isEmpty && !viewModel.isRefreshing {
                    emptyState
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var groupedList: some View {
        ScrollView {
            // One flat LazyVStack with a Section per repo, so rows inside a
            // large repo are created lazily too (a nested non-lazy VStack
            // would instantiate every row of a group at once).
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.groupedSkills) { group in
                    Section {
                        ForEach(group.skills) { skill in
                            SkillRow(skill: skill, onInstall: { onInstall(skill) })
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 11))
                            Text(group.repo)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text("(\(group.skills.count))")
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.textMuted)
                        }
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                    }
                }
                if viewModel.groupedSkills.isEmpty && !viewModel.isRefreshing {
                    emptyState
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Text(viewModel.lastError ?? "No skills match your search")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var shouldDim: Bool {
        viewModel.isRefreshing && viewModel.skills.isEmpty
    }

    private var loadingCard: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(AppTheme.Colors.textPrimary)
            Text("Fetching skills.sh catalogue…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(AppTheme.Colors.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 18)
    }
}

private struct SkillRow: View {
    let skill: MarketplaceSkill
    let onInstall: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(skill.source)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(skill.installCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Text(formattedInstalls)
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Colors.textMuted)
                .frame(minWidth: 70, alignment: .trailing)
            Button(action: onInstall) {
                Text("Install")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(AppTheme.Colors.accent.opacity(isHovering ? 0.9 : 0.75))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? AppTheme.Colors.tabBackground.opacity(0.4) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(skill.installCommand)
        .contextMenu {
            Button("Install in Active Tab") { onInstall() }
            Divider()
            Button("Copy Install Command") { copy(skill.installCommand) }
            Button("Copy Skill ID") { copy(skill.id) }
            if let url = skill.skillsURL {
                Button("Open on skills.sh") { NSWorkspace.shared.open(url) }
            }
            if let url = skill.githubURL {
                Button("Open Repo on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var formattedInstalls: String {
        let v = skill.installs
        if v >= 1_000_000 { return String(format: "%.1fM", Double(v) / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", Double(v) / 1_000) }
        return "\(v)"
    }

    private func copy(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }
}
