//
//  AttentionNotifier.swift
//  Xylem
//
//  Tells the user that Claude in a tab they are not looking at finished
//  or asks for input: the Dock badge (number of such tabs) and a macOS
//  notification per episode (both on by default, notifications behind
//  a Settings switch). Clicking the notification brings Xylem forward on
//  that tab.
//
//  Also announces a downloaded Xylem update (AppUpdater): it installs on
//  quit; clicking the notification opens Sparkle's window to install now.
//
//  Permission is asked the first time something would be announced, not
//  at launch. Badge writes are skipped when the count is unchanged (the
//  tracker reports it every second).
//

import AppKit
import UserNotifications

@MainActor
protocol AttentionNotifying: AnyObject {
    func setBadgeCount(_ count: Int)
    func announce(tabID: UUID, title: String, state: ClaudeTabState, lastPrompt: String?)
    func withdraw(tabID: UUID)
}

@MainActor
final class AttentionNotifier: NSObject, AttentionNotifying {
    /// Opens the tab a clicked notification belongs to.
    var onOpenTab: (UUID) -> Void = { _ in }
    /// The update notification was clicked.
    var onShowUpdate: () -> Void = {}

    private var badgeCount = 0
    private var authorization: Task<Bool, Never>?
    private nonisolated static let tabIDKey = "tabID"
    private nonisolated static let updateCategory = "xylem.update-ready"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Not behind the Claude notifications switch: it is about Xylem itself
    /// and comes at most once per version.
    func announceUpdateReady(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Xylem \(version) is ready"
        content.body = "It installs when you quit Xylem. Click to see what's new or install it now."
        content.categoryIdentifier = Self.updateCategory
        let request = UNNotificationRequest(identifier: Self.updateCategory, content: content, trigger: nil)
        Task {
            guard await self.isAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    func setBadgeCount(_ count: Int) {
        guard count != badgeCount else { return }
        badgeCount = count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func announce(tabID: UUID, title: String, state: ClaudeTabState, lastPrompt: String?) {
        guard AppSettings.notifyWhenClaudeWaits, let body = Self.body(for: state, lastPrompt: lastPrompt) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.tabIDKey: tabID.uuidString]
        content.threadIdentifier = tabID.uuidString
        if case .needsInput = state { content.sound = .default }
        // One live notification per tab: a newer episode replaces it.
        let request = UNNotificationRequest(identifier: tabID.uuidString, content: content, trigger: nil)
        Task {
            guard await self.isAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// The tab is being looked at: its notification is old news.
    func withdraw(tabID: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
    }

    nonisolated static func body(for state: ClaudeTabState, lastPrompt: String?) -> String? {
        switch state {
        case .needsInput(let message):
            return message.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude needs your input"
        case .finished:
            guard let prompt = lastPrompt, !prompt.isEmpty else { return "Claude finished" }
            return "Claude finished: \(prompt)"
        default:
            return nil
        }
    }

    private func isAuthorized() async -> Bool {
        if let authorization { return await authorization.value }
        let task = Task { () -> Bool in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional: return true
            case .notDetermined:
                return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            default: return false
            }
        }
        authorization = task
        let granted = await task.value
        // A denial may be lifted in System Settings later: ask again then.
        if !granted { authorization = nil }
        return granted
    }
}

extension AttentionNotifier: UNUserNotificationCenterDelegate {
    /// Banners also while Xylem is frontmost: the tab may be a background one.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.content.categoryIdentifier == Self.updateCategory {
            await MainActor.run {
                NSApp.activate()
                self.onShowUpdate()
            }
            return
        }
        guard let raw = response.notification.request.content.userInfo[Self.tabIDKey] as? String,
              let id = UUID(uuidString: raw)
        else { return }
        await MainActor.run {
            NSApp.activate()
            self.onOpenTab(id)
        }
    }
}
