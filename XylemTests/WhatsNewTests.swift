//
//  WhatsNewTests.swift
//  XylemTests
//
//  "What's new" shows a staged update's notes once, on its own version's
//  first launch, and parses our release-notes markdown.
//

import Testing
import Foundation

struct WhatsNewTests {
    private func defaults() -> UserDefaults {
        let name = "xylem-whatsnew-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func notesShowOnceOnTheirVersionsFirstLaunch() {
        let store = defaults()
        WhatsNewStore.remember(version: "1.2.1", notes: "### New\n- Thing", defaults: store)
        // Still on the old version (staged, not installed): kept.
        #expect(WhatsNewStore.take(runningVersion: "1.2.0", defaults: store) == nil)
        #expect(WhatsNewStore.take(runningVersion: "1.2.1", defaults: store)?.notes == "### New\n- Thing")
        // Once.
        #expect(WhatsNewStore.take(runningVersion: "1.2.1", defaults: store) == nil)
    }

    @Test func notesOfAnOlderVersionAreDropped() {
        let store = defaults()
        WhatsNewStore.remember(version: "1.2.1", notes: "- Old", defaults: store)
        // Installed by hand straight to a later version.
        #expect(WhatsNewStore.take(runningVersion: "1.10.0", defaults: store) == nil)
        #expect(WhatsNewStore.take(runningVersion: "1.2.1", defaults: store) == nil)
    }

    @Test func installAndRelaunchFromSparklesWindowShowsNothingAgain() {
        let store = defaults()
        WhatsNewStore.remember(version: "1.2.1", notes: "- Thing", defaults: store)
        WhatsNewStore.forget(defaults: store)
        #expect(WhatsNewStore.take(runningVersion: "1.2.1", defaults: store) == nil)
    }

    @Test func emptyNotesAreNotKept() {
        let store = defaults()
        WhatsNewStore.remember(version: "1.2.1", notes: "  \n", defaults: store)
        #expect(WhatsNewStore.take(runningVersion: "1.2.1", defaults: store) == nil)
    }

    @Test func parsesOurReleaseNotes() {
        let notes = ReleaseNotes(markdown: """
            ### New
            - **A loader.** While a tab starts.

            ### Fixed
            - Esc.
            - Another `fix`.
            """)
        #expect(notes.sections.map(\.title) == ["New", "Fixed"])
        #expect(notes.sections[0].items == ["**A loader.** While a tab starts."])
        #expect(notes.sections[1].items.count == 2)
        // Text before any heading still shows.
        #expect(ReleaseNotes(markdown: "Just a line").sections.first?.items == ["Just a line"])
    }
}
