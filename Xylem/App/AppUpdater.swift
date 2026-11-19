//
//  AppUpdater.swift
//  Xylem
//
//  Updates through Sparkle 2. The feed is appcast.xml on the public
//  t1nkl/xylem GitHub Pages site (SUFeedURL in
//  Config/Xylem-Info.plist, with the EdDSA public key and the hourly check
//  interval). Every update is EdDSA-signed by scripts/make-dmg.sh.
//
//  Updates download in the background and install when the user quits
//  (a relaunch would cut off claude in every tab). When one
//  is ready, a notification says so, and it stays visible in the window
//  (a "New update available" toolbar capsule, `readyVersion`) and as the first
//  item of the Xylem menu: Xylem stays open for days, and one missed
//  banner would leave an update waiting unseen. A click on
//  any of them, or Check for Updates…, opens Sparkle's window with the
//  release notes and Install and Relaunch / Install on Quit. A relaunch
//  goes through applicationShouldTerminate, so the quit confirmation still
//  guards a running turn.
//
//  The delegate lets Sparkle end its session once the update is staged
//  (returns false from willInstallUpdateOnQuit): keeping it open, to call
//  the immediate-install block ourselves, disables Check for Updates… and
//  with it the window.
//
//  Starts only in Release builds: a Debug run would offer the published
//  version over the one being developed. `defaults write <bundle id>
//  disableUpdater -bool YES` turns it off in test copies; `updateFeedURL`
//  points one at a local feed (updates must still carry our signature).
//

import AppKit
import Combine
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater: NSObject {
    /// For the menu item: false while a check is already running.
    private(set) var canCheckForUpdates = false
    /// The Settings toggle: automatic checks only. Background downloading is
    /// Sparkle's own checkbox in its update window; setting it here too
    /// would re-enable it on every launch. A stored copy, so the
    /// toggle re-renders when it changes.
    var automaticallyChecks = false {
        didSet {
            guard isRunning, automaticallyChecks != oldValue else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    /// False in Debug builds and test copies: the menu item and the toggle
    /// are disabled.
    let isRunning: Bool
    /// The version downloaded and waiting to install on quit; nil while
    /// there is none. Drives the toolbar capsule and the menu item.
    private(set) var readyVersion: String?

    /// Sends "update ready" notifications and their clicks back here.
    var notifier: AttentionNotifier? {
        didSet {
            notifier?.onShowUpdate = { [weak self] in self?.checkForUpdates() }
        }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckSubscription: AnyCancellable?
    /// A staged update is reported again by every scheduled check (hourly);
    /// one notification per version per launch is enough.
    @ObservationIgnored private var announcedVersion: String?

    /// A computed property, not an inline `#if`: a literal `false` in Debug
    /// made the compiler flag the rest of `init` "will never be executed".
    private static var isEnabledInThisBuild: Bool {
        #if DEBUG
        false
        #else
        !UserDefaults.standard.bool(forKey: "disableUpdater")
        #endif
    }

    override init() {
        let enabled = Self.isEnabledInThisBuild
        isRunning = enabled
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: self, userDriverDelegate: nil)
        guard enabled else { return }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        canCheckSubscription = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    func checkForUpdates() {
        guard isRunning else { return }
        controller.checkForUpdates(nil)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        // Test copies only; nil = SUFeedURL from Info.plist.
        UserDefaults.standard.string(forKey: "updateFeedURL")
    }

    /// Install and Relaunch from Sparkle's window, which showed the notes:
    /// no "What's new" again after the relaunch. (Cancelled at the quit
    /// confirmation, the next hourly report keeps them again.)
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        WhatsNewStore.forget()
    }

    /// Skip This Version drops the staged update: nothing waits.
    /// Sparkle calls its delegate on the main thread.
    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard choice == .skip else { return }
        WhatsNewStore.forget()
        MainActor.assumeIsolated { readyVersion = nil }
    }

    /// A downloaded update is staged and installs on quit: tell the user.
    /// Sparkle calls its delegate on the main thread.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        // For "What's new" on that version's first launch: installing on
        // quit shows no notes.
        if let notes = item.itemDescription { WhatsNewStore.remember(version: version, notes: notes) }
        MainActor.assumeIsolated {
            if readyVersion != version { readyVersion = version }
            guard announcedVersion != version else { return }
            announcedVersion = version
            notifier?.announceUpdateReady(version: version)
        }
        return false
    }
}
