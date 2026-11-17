//
//  HotkeyBindingTests.swift
//  XylemTests
//
//  Parser for the shortcut-description strings the Settings → Hotkeys UI
//  accepts. The glyph form (⌘⇧D) must round-trip with the token form.
//

import Testing
import Foundation
import SwiftUI

struct HotkeyBindingTests {

    @Test func parsesTokenFormCaseInsensitive() throws {
        let binding = try #require(HotkeyBinding.parse("Cmd+Shift+D"))
        #expect(binding.key == "d")
        #expect(Set(binding.modifiers) == Set(["cmd", "shift"]))
    }

    @Test func parsesGlyphForm() throws {
        let binding = try #require(HotkeyBinding.parse("⌘⇧D"))
        #expect(binding.key == "d")
        #expect(Set(binding.modifiers) == Set(["cmd", "shift"]))
    }

    @Test func parsesNamedKeyForArrows() throws {
        let binding = try #require(HotkeyBinding.parse("cmd+option+leftArrow"))
        #expect(binding.key == "leftarrow")
        #expect(Set(binding.modifiers) == Set(["cmd", "option"]))
    }

    @Test func rejectsModifierOnlyString() {
        #expect(HotkeyBinding.parse("cmd+shift") == nil)
    }

    @Test func displayUsesCanonicalGlyphOrder() {
        let b = HotkeyBinding(key: "d", modifiers: ["shift", "cmd"])
        // Order is control, option, shift, cmd - so ⇧ comes before ⌘ here.
        #expect(b.display == "⇧⌘D")
    }

    @Test func eventModifiersContainAllRequestedFlags() {
        let b = HotkeyBinding(key: "d", modifiers: ["cmd", "shift", "option", "control"])
        let mods = b.eventModifiers
        #expect(mods.contains(.command))
        #expect(mods.contains(.shift))
        #expect(mods.contains(.option))
        #expect(mods.contains(.control))
    }

    @Test func keyEquivalentNormalisesSingleCharacter() {
        let b = HotkeyBinding(key: "D", modifiers: ["cmd"])
        #expect(b.keyEquivalent == KeyEquivalent("d"))
    }

    @Test func keyEquivalentMapsNamedKeys() {
        let up = HotkeyBinding(key: "upArrow", modifiers: []).keyEquivalent
        let esc = HotkeyBinding(key: "escape", modifiers: []).keyEquivalent
        #expect(up == .upArrow)
        #expect(esc == .escape)
    }
}

/// HotkeyStore reads keybindings.json once and serves later lookups from
/// memory; writes re-read the file first so hand edits survive. Each test
/// uses its own temp file - never ~/.xylem.
@MainActor
struct HotkeyOverridesStoreTests {

    private func makeStore(_ json: String? = nil) throws -> HotkeyOverridesStore {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "xylem-hotkeys-\(UUID().uuidString)/keybindings.json")
        if let json {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: url)
        }
        return HotkeyOverridesStore(fileURL: url)
    }

    private func cleanUp(_ store: HotkeyOverridesStore) {
        try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent())
    }

    @Test func repeatedReadsHitDiskOnce() throws {
        let store = try makeStore(#"{"newTab":{"key":"n","modifiers":["cmd"]}}"#)
        defer { cleanUp(store) }

        for _ in 0..<9 { _ = store.overrides() }

        #expect(store.diskReadCount == 1)
        #expect(store.overrides()["newTab"] == HotkeyBinding(key: "n", modifiers: ["cmd"]))
    }

    @Test func invalidatePicksUpExternalEdits() throws {
        let store = try makeStore(#"{}"#)
        defer { cleanUp(store) }
        #expect(store.overrides().isEmpty)

        try Data(#"{"clear":{"key":"k","modifiers":["cmd"]}}"#.utf8).write(to: store.fileURL)
        #expect(store.overrides().isEmpty)          // still the cached copy

        store.invalidate()
        #expect(store.overrides()["clear"] == HotkeyBinding(key: "k", modifiers: ["cmd"]))
    }

    @Test func setKeepsHandEditsMadeAfterLoadAndRefreshesCache() throws {
        let store = try makeStore(#"{}"#)
        defer { cleanUp(store) }
        _ = store.overrides()

        try Data(#"{"clear":{"key":"k","modifiers":["cmd"]}}"#.utf8).write(to: store.fileURL)
        store.set(HotkeyBinding(key: "n", modifiers: ["cmd"]), for: .newTab)

        let readsAfterSet = store.diskReadCount
        let overrides = store.overrides()
        #expect(store.diskReadCount == readsAfterSet)   // served from the updated cache
        #expect(Set(overrides.keys) == ["clear", "newTab"])

        store.reset(.clear)
        #expect(Set(store.overrides().keys) == ["newTab"])
    }

    @Test func resolveAppliesKnownOverridesOnly() {
        let resolved = HotkeyStore.resolve(overrides: [
            "newTab": HotkeyBinding(key: "n", modifiers: ["cmd"]),
            "notAnAction": HotkeyBinding(key: "x", modifiers: ["cmd"])
        ])
        #expect(resolved[.newTab] == HotkeyBinding(key: "n", modifiers: ["cmd"]))
        #expect(resolved[.closeTab] == HotkeyStore.defaults[.closeTab])
        #expect(resolved.count == HotkeyAction.allCases.count)
    }
}
