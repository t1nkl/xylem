//
//  TabDetails.swift
//  Xylem
//
//  What a tab's claude runs with beyond its state, for the tab list, the
//  top tabs' hover card and the toolbar: its permission mode, background
//  tasks still running and its prompt cache. The texts are one pure enum so
//  every place words them alike.
//
//  Times are absolute ("until 14:32"), not countdowns: the hover card is
//  drawn when it appears and would show a stale "in 12 min". The toolbar's
//  cache item is the one countdown, and it redraws itself.
//

import SwiftUI

nonisolated enum TabDetailText {
    /// Claude Code's permission mode in its own words (the footer's).
    static func permissionModeName(_ mode: String) -> String {
        switch mode {
        case "default": return "Default"
        case "plan": return "Plan mode"
        case "acceptEdits": return "Accept edits"
        case "auto": return "Auto mode"
        case "dontAsk": return "Don't ask"
        case "bypassPermissions": return "Bypass permissions"
        default: return mode
        }
    }

    /// The modes the tab list marks: plan (Claude only reads and plans) and
    /// bypass (nothing is asked). The others show in the details only, so
    /// a user whose default is auto doesn't get a mark on every tab.
    enum Badge: Equatable { case plan, bypass }

    static func badge(for mode: String?) -> Badge? {
        switch mode {
        case "plan": return .plan
        case "bypassPermissions": return .bypass
        default: return nil
        }
    }

    /// "2 background tasks running"; nil for none.
    static func backgroundTasks(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 background task running" : "\(count) background tasks running"
    }

    /// "Prompt cache warm until 14:32", or once it has expired "Prompt cache
    /// expired at 14:32: the next message writes 136K tokens again".
    static func promptCache(_ cache: ClaudeLiveStatus.PromptCache, now: Date) -> String {
        let time = PlanLimitsToolbarItem.dayTime(cache.expiresAt, now: now)
        guard !cache.isWarm(at: now) else { return "Prompt cache warm until \(time)" }
        let base = "Prompt cache expired at \(time)"
        guard let tokens = cache.recacheTokens else { return base }
        return base + ": the next message writes \(ContextRingItem.tokens(tokens)) tokens again"
    }

    /// The details of a tab beyond its state, one per line.
    static func lines(permissionMode: String?, taskCount: Int,
                      cache: ClaudeLiveStatus.PromptCache?, now: Date) -> [String] {
        var lines: [String] = []
        if let mode = permissionMode, mode != "default" { lines.append(permissionModeName(mode)) }
        if let tasks = backgroundTasks(taskCount) { lines.append(tasks) }
        if let cache { lines.append(promptCache(cache, now: now)) }
        return lines
    }

    /// Minutes left before the cache expires, when that is soon enough to
    /// mention (`soon`); nil when warm for longer or already expired.
    static func minutesLeft(_ cache: ClaudeLiveStatus.PromptCache, now: Date,
                            soon: TimeInterval = 10 * 60) -> Int? {
        let left = cache.expiresAt.timeIntervalSince(now)
        guard left > 0, left <= soon else { return nil }
        return max(1, Int((left / 60).rounded(.up)))
    }
}

extension TerminalTab {
    /// `TabDetailText.lines` for this tab. `includingCache` reads the status
    /// line input, which changes with every request: only for views drawn
    /// on demand (the hover card), not for a tab row.
    func detailLines(includingCache: Bool, now: Date = Date()) -> [String] {
        TabDetailText.lines(permissionMode: permissionMode, taskCount: runningBackgroundTasks,
                            cache: includingCache ? liveStatus?.promptCache : nil, now: now)
    }
}

/// "Plan" in blue or "Bypass" in red after a tab's title.
struct PermissionModeBadge: View {
    let mode: String?

    var body: some View {
        if let badge = TabDetailText.badge(for: mode) {
            let (text, color) = Self.look(badge)
            // Solid, so it reads on the active row's selection colour too.
            Text(text)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(color))
                .fixedSize()
                .help(TabDetailText.permissionModeName(mode ?? ""))
                .accessibilityLabel(TabDetailText.permissionModeName(mode ?? ""))
        }
    }

    private static func look(_ badge: TabDetailText.Badge) -> (String, Color) {
        switch badge {
        case .plan: return ("Plan", AppTheme.Colors.statusBlue)
        case .bypass: return ("Bypass", AppTheme.Colors.statusRed)
        }
    }
}

/// A gears glyph and the count, for a tab whose claude has background
/// tasks running.
struct BackgroundTasksMark: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 9, weight: .medium))
                Text("\(count)").monospacedDigit()
            }
            .fixedSize()
            .help(TabDetailText.backgroundTasks(count) ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TabDetailText.backgroundTasks(count) ?? "")
        }
    }
}

/// The active tab's prompt cache in the toolbar, only when it matters: a
/// snowflake once it has expired (the next message writes the whole
/// conversation to the cache again), minutes left in amber when it expires
/// within 10 minutes, nothing otherwise. Redraws twice a minute, and only
/// while the tab has a cache to show.
struct PromptCacheToolbarItem: View {
    let cache: ClaudeLiveStatus.PromptCache?

    var body: some View {
        if let cache {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(cache, now: context.date)
            }
        }
    }

    /// Gap to the item before it, part of the item so an empty one takes none.
    static let leadingGap: CGFloat = 8

    @ViewBuilder
    private func content(_ cache: ClaudeLiveStatus.PromptCache, now: Date) -> some View {
        if !cache.isWarm(at: now) {
            Image(systemName: "snowflake")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Colors.statusBlue)
                .instantTooltip(TabDetailText.promptCache(cache, now: now))
                .accessibilityLabel(TabDetailText.promptCache(cache, now: now))
                .padding(.leading, Self.leadingGap)
        } else if let minutes = TabDetailText.minutesLeft(cache, now: now) {
            HStack(spacing: 2) {
                Image(systemName: "timer")
                Text("\(minutes)m").monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppTheme.Colors.statusAmber)
            .instantTooltip(TabDetailText.promptCache(cache, now: now))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TabDetailText.promptCache(cache, now: now))
            .padding(.leading, Self.leadingGap)
        }
    }
}
