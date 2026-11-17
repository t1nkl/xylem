//
//  HoverHighlight.swift
//  Xylem
//
//  The one hover look for small plain buttons (strip, footer, close ×): a
//  faint rounded fill that fades in. Same tint as the bottom strip's
//  buttons and the right panel's rows.
//

import SwiftUI

struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 5
    var isEnabled = true
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
            )
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 5, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }
}
