//
//  KeyboardCheatsheet.swift
//  Xylem
//
//  ⌘/ overlay listing every keyboard shortcut Xylem responds to. Groups
//  are static; individual bindings pull their live values from HotkeyStore
//  so a user who overrides ⌘T to ⌘N sees the override here too.
//
//  Rows are keyed by label (stable across renders, unlike a fresh UUID per
//  evaluation) and bindings come from HotkeyStore's in-memory cache rather
//  than a disk read per render.
//

import SwiftUI

struct KeyboardCheatsheet: View {
    let onClose: () -> Void

    private struct Row: Identifiable {
        var id: String { label }
        let label: String
        let binding: String
    }

    private struct Group: Identifiable {
        var id: String { title }
        let title: String
        let rows: [Row]
    }

    /// Built once per view value - not per body evaluation.
    private let groups: [Group] = KeyboardCheatsheet.makeGroups()

    private static func makeGroups() -> [Group] {
        let all = HotkeyStore.all()
        func b(_ action: HotkeyAction) -> String {
            all[action]?.display ?? "-"
        }
        return [
            Group(title: "App", rows: [
                Row(label: "Command Palette",  binding: b(.commandPalette)),
                Row(label: "Open Folder",      binding: b(.openFolder)),
                Row(label: "Usage Dashboard",  binding: "⌘U"),
                Row(label: "Keyboard Shortcuts", binding: "⌘/"),
                Row(label: "Settings",         binding: "⌘,")
            ]),
            Group(title: "Panels", rows: [
                Row(label: "Tab List",         binding: b(.toggleTabList)),
                Row(label: "Claude / Git Panel", binding: b(.togglePanel)),
                Row(label: "Claude",           binding: b(.showClaude)),
                Row(label: "Git",              binding: b(.showGit)),
                Row(label: "Files",            binding: b(.showFiles)),
                Row(label: "Changes",          binding: b(.showChanges))
            ]),
            Group(title: "Tabs", rows: [
                Row(label: "New Tab",            binding: b(.newTab)),
                Row(label: "Close Tab",          binding: b(.closeTab)),
                Row(label: "Close Other Tabs",   binding: b(.closeOtherTabs)),
                Row(label: "Next Waiting Tab",   binding: b(.nextWaitingTab)),
                Row(label: "Switch to Tab N",    binding: "⌘1 … ⌘9")
            ]),
            Group(title: "Terminal", rows: [
                Row(label: "Clear",            binding: b(.clear)),
                Row(label: "Interrupt",        binding: b(.interrupt)),
                Row(label: "Find",             binding: b(.findInTerminal)),
                Row(label: "Find Next",        binding: b(.findNextMatch)),
                Row(label: "Find Previous",    binding: b(.findPreviousMatch))
            ])
        ]
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        groupBlock(group)
                    }
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 680, height: 480)
        .background(AppTheme.Colors.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundStyle(AppTheme.Colors.accent)
            Text("Keyboard Shortcuts")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Colors.panelBorder).frame(height: 0.5)
        }
    }

    private var footer: some View {
        HStack {
            Text("Edit bindings in Settings → Hotkeys")
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Colors.textMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.Colors.panelBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Colors.panelBorder).frame(height: 0.5)
        }
    }

    private func groupBlock(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textMuted)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(group.rows) { row in
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.system(size: 12))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Spacer(minLength: 8)
                        Text(row.binding)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(AppTheme.Colors.panelBorder, lineWidth: 0.5)
                            )
                    }
                }
            }
        }
    }
}
