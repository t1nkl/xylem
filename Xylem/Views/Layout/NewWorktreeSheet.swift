//
//  NewWorktreeSheet.swift
//  Xylem
//
//  Asks for the branch of a new worktree tab (GitWorktreeCreator) and shows
//  git's own message when it can't be made. A new branch starts from the
//  active tab's HEAD; an existing one that isn't checked out is reused.
//

import SwiftUI

struct NewWorktreeSheet: View {
    /// Branch the active tab is on - what a new branch starts from.
    let baseBranch: String?
    let repositoryName: String
    /// Creates the worktree and opens its tab; throws with a message to show.
    let create: (String) async throws -> Void
    let onClose: () -> Void

    @State private var branch = ""
    @State private var isCreating = false
    @State private var failure: String?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Worktree Tab")
                    .font(.system(size: 15, weight: .semibold))
                Text("A separate checkout of \(repositoryName) with its own branch, so a second Claude can work without touching this tab's files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Branch name", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .disabled(isCreating)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.statusAmber)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isCreating)
            }
        }
        .padding(20)
        .frame(width: 420)
        // Next turn: set in onAppear itself, the focus was lost while the
        // sheet replaced the palette (seen live - no ring, typing went nowhere).
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var hint: String {
        let folder = trimmed.isEmpty ? "<branch>" : trimmed.replacingOccurrences(of: "/", with: "-")
        let base = baseBranch.map { "New branches start from \($0). " } ?? ""
        return base + "Folder: .claude/worktrees/\(folder)"
    }

    private func submit() {
        guard !trimmed.isEmpty, !isCreating else { return }
        isCreating = true
        failure = nil
        let name = trimmed
        Task {
            do {
                try await create(name)
                onClose()
            } catch {
                failure = error.localizedDescription
                isCreating = false
                // The field was disabled while git ran and lost the focus;
                // give it back so the name can be fixed right away.
                fieldFocused = true
            }
        }
    }
}
