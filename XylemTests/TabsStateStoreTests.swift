//
//  TabsStateStoreTests.swift
//  XylemTests
//
//  On-disk tab state: files written before `hasCustomTitle` existed must
//  still load, and the background writer must land the newest state.
//

import Testing
import Foundation

@MainActor
struct TabsStateStoreTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xylem-tabs-\(UUID().uuidString)")
            .appendingPathComponent("tabs-state.json")
    }

    @Test func decodesLegacyFileWithoutCustomTitleFlag() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let id = UUID().uuidString
        let legacy = """
        {"activeTabID":"\(id)","tabs":[{"id":"\(id)","title":"api","workingDirectory":"/tmp"}]}
        """
        try Data(legacy.utf8).write(to: url)

        let state = TabsStateStore(fileURL: url).load()
        #expect(state?.tabs.count == 1)
        #expect(state?.tabs.first?.title == "api")
        #expect(state?.tabs.first?.hasCustomTitle == false)
    }

    @Test func flushLandsNewestSaveOnDisk() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = TabsStateStore(fileURL: file)
        let id = UUID()
        for index in 0..<20 {
            store.save(PersistedTabsState(
                tabs: [PersistedTab(
                    id: id,
                    title: "v\(index)",
                    workingDirectory: nil,
                    hasCustomTitle: index.isMultiple(of: 2)
                )],
                activeTabID: id
            ))
        }
        store.flush()
        let loaded = store.load()
        #expect(loaded?.tabs.first?.title == "v19")
        #expect(loaded?.tabs.first?.hasCustomTitle == false)
    }
}
