//
//  XylemMark.swift
//  Xylem
//
//  Programmatic brand mark - two crossed rounded bars forming an "X".
//  Used wherever the app needs to identify itself: onboarding hero, tab
//  avatars, future about/about-this-app surfaces. Built as a SwiftUI
//  shape stack so it scales pixel-clean at any size and tints to any
//  colour without managing template-image assets.
//

import SwiftUI

struct XylemMark: View {
    let size: CGFloat
    let color: Color

    /// Background-circle treatment is opt-in. Tab avatars use the bare
    /// glyph (the avatar's own circle is the background); the onboarding
    /// hero uses the bare glyph too. Future surfaces (e.g. About) might
    /// want the wrapped variant.
    var withCircle: Bool = false

    var body: some View {
        ZStack {
            if withCircle {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: size, height: size)
            }
            ZStack {
                bar
                    .rotationEffect(.degrees(45))
                bar
                    .rotationEffect(.degrees(-45))
            }
            .frame(width: size, height: size)
        }
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: barWidth * 0.45, style: .continuous)
            .fill(color)
            .frame(width: barWidth, height: barLength)
    }

    /// Bar geometry tuned by eye to read as a thick X without looking
    /// either spindly or like a plus sign.
    private var barWidth: CGFloat { size * 0.22 }
    private var barLength: CGFloat { size * 0.78 }
}
