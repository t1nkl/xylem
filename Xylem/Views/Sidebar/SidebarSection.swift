//
//  SidebarSection.swift
//  Xylem
//
//  Collapsible section of the right panel (inspector): a disclosure chevron
//  leading, the Title Case header in semibold primary text, the count after
//  it in tertiary, and an optional action (e.g. "+") revealed on hover at
//  the right edge.
//  Compact density: the whole header is one hit target that toggles the
//  section.
//

import SwiftUI

/// Panel-local layout values (Compact density). Not in AppTheme on purpose:
/// they only make sense inside the right panel.
enum SidebarLayout {
    /// Horizontal inset of headers and rows from the panel edges.
    static let gutter: CGFloat = 12
    /// Right inset of row content (times, counts).
    static let rowTrailing: CGFloat = 14
    /// Right inset of header trailing controls.
    static let headerTrailing: CGFloat = 10
    /// Section header type.
    static let headerFont = AppTheme.Fonts.sectionHeader
    /// Section header height; also the pitch between collapsed sections.
    static let headerHeight: CGFloat = 30
    /// Session row height.
    static let rowHeight: CGFloat = 28
    /// Height of compact list rows (directories, skills, agents, …).
    static let compactRowHeight: CGFloat = 26
    /// Leading indent of section content under its header.
    static let childIndent: CGFloat = 4
    /// Space after an expanded section's last row.
    static let sectionBottomPadding: CGFloat = 6
    /// Inset of the rounded hover highlight from the panel edges.
    static let hoverInset: CGFloat = 6
    /// Hover highlight fill.
    static let hoverFill = Color.primary.opacity(0.07)
}

/// Optional header action of a `SidebarSection` (e.g. a "+"), shown on
/// header hover. Top-level (not nested in the generic section) so one value
/// can be shared across content types.
struct SidebarTrailingAction {
    let systemImage: String
    let tooltip: String
    let action: () -> Void

    static func plus(tooltip: String, action: @escaping () -> Void) -> SidebarTrailingAction {
        SidebarTrailingAction(systemImage: "plus", tooltip: tooltip, action: action)
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    let count: Int?
    var defaultExpanded: Bool = false
    var trailingAction: TrailingAction? = nil
    @State private var isExpanded: Bool
    @State private var isHeaderHovering: Bool = false
    @ViewBuilder let content: () -> Content

    typealias TrailingAction = SidebarTrailingAction

    init(
        title: String,
        count: Int? = nil,
        defaultExpanded: Bool = false,
        trailingAction: TrailingAction? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.count = count
        self.defaultExpanded = defaultExpanded
        self.trailingAction = trailingAction
        self._isExpanded = State(initialValue: defaultExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                // Wrapped so the paddings apply to the block, not to every
                // child of the @ViewBuilder tuple.
                VStack(alignment: .leading, spacing: 0) { content() }
                    .padding(.leading, SidebarLayout.childIndent)
                    .padding(.bottom, SidebarLayout.sectionBottomPadding)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHeaderHovering ? AppTheme.Colors.textSecondary : AppTheme.Colors.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    Text(title)
                        .font(SidebarLayout.headerFont)
                        .foregroundStyle(AppTheme.Colors.panelText)
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(AppTheme.Fonts.sectionMeta)
                            .foregroundStyle(AppTheme.Colors.textMuted)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A plain-style button exposes no text to VoiceOver by itself.
            .accessibilityLabel(count.map { $0 > 0 ? "\(title), \($0)" : title } ?? title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        // The action floats at the right edge instead of taking layout
        // space, so the header text never shifts when it appears.
        .overlay(alignment: .trailing) {
            if let trailingAction {
                Button(action: trailingAction.action) {
                    Image(systemName: trailingAction.systemImage)
                        .font(.system(size: AppTheme.Icons.button, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(trailingAction.tooltip)
                .accessibilityLabel(trailingAction.tooltip)
                .opacity(isHeaderHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHeaderHovering)
                .padding(.trailing, 2)
            }
        }
        .padding(.leading, SidebarLayout.gutter)
        .padding(.trailing, SidebarLayout.headerTrailing)
        .frame(height: SidebarLayout.headerHeight)
        .onHover { isHeaderHovering = $0 }
    }
}

/// Full-width row container shared by panel rows: fixed height, gutter
/// padding and a rounded `surfaceHover` highlight when `isInteractive`.
struct SidebarRow<Content: View>: View {
    var height: CGFloat = SidebarLayout.rowHeight
    var isInteractive: Bool = true
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.leading, SidebarLayout.gutter)
            .padding(.trailing, SidebarLayout.rowTrailing)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isInteractive && isHovering ? SidebarLayout.hoverFill : .clear)
                    .padding(.horizontal, SidebarLayout.hoverInset)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                guard isInteractive else { return }
                isHovering = hovering
            }
    }
}

/// Full-width two-or-more-way switch for the panel's top rows (Claude/Git, This
/// project/All). A system segmented `Picker` on macOS keeps its intrinsic width
/// and centres itself, so the two rows would differ in width; these segments
/// are equal and full-width. Exposed to accessibility as a group of selectable
/// buttons.
struct PanelSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.white : AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? AppTheme.Colors.segmentTint : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}
