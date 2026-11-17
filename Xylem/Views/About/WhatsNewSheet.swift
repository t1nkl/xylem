//
//  WhatsNewSheet.swift
//  Xylem
//
//  The release notes of the version just installed, once, on its first
//  launch (WhatsNewStore). Items keep their inline markdown (bold, code).
//

import SwiftUI

struct WhatsNewSheet: View {
    let version: String
    let notes: ReleaseNotes
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                XylemMark(size: 24, color: AppTheme.Colors.accent)
                    .accessibilityHidden(true)
                Text("What's new in Xylem \(version)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(notes.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 6) {
                            if let title = section.title {
                                Text(title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(AppTheme.Colors.accent).accessibilityHidden(true)
                                    Text(Self.inline(item))
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppTheme.Colors.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Continue", action: onClose)
                    .keyboardShortcut(.defaultAction)
                // Esc closes it too.
                Button("", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(AppTheme.Colors.background)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
