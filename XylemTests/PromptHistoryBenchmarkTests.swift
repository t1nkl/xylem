//
//  PromptHistoryBenchmarkTests.swift
//  XylemTests
//
//  Measures the prompt index on the real `~/.claude/projects` (read only,
//  index in a temp file) and checks that the byte pre-filter loses no
//  prompt: a full decode of every line through UserPromptExtractor must
//  find exactly as many. Off by default; run with
//  `TEST_RUNNER_XYLEM_PROMPT_BENCH=<report path> xcodebuild … test`.
//

import Testing
import Foundation

struct PromptHistoryBenchmarkTests {

    nonisolated private static let reportPath = ProcessInfo.processInfo.environment["XYLEM_PROMPT_BENCH"]

    private static func seconds(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    @Test(.enabled(if: reportPath != nil))
    func realTranscripts() throws {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
        let indexURL = FileManager.default.temporaryDirectory
            .appending(path: "xylem-prompt-bench-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        let indexer = PromptHistoryIndexer(projectsDirectory: projects, store: PromptHistoryStore(url: indexURL))
        var report: [String] = []

        var cold = PromptHistoryIndexer.Update(records: [:], changed: false, promptsChanged: false)
        report.append("cold build: \(Self.seconds { cold = indexer.update([:]) }) s")
        let indexed = cold.records.values.reduce(0) { $0 + $1.prompts.count }
        let size = (try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.size] as? Int) ?? 0
        let capped = cold.records.values.reduce(0) { sum, record in
            sum + record.prompts.filter { $0.text.count == PromptHistoryIndexer.promptCharacterLimit }.count
        }
        report.append("files: \(cold.records.count), prompts: \(indexed) (\(capped) capped), index file: \(size) bytes")

        var warm = cold
        report.append("warm update (in memory): \(Self.seconds { warm = indexer.update(cold.records) }) s, changed: \(warm.changed), prompts changed: \(warm.promptsChanged)")

        var loaded: [String: PromptHistoryFileRecord] = [:]
        report.append("load saved index: \(Self.seconds { loaded = indexer.loadStored() }) s")
        report.append("warm update after relaunch (load + update): \(Self.seconds { _ = indexer.update(indexer.loadStored()) }) s")

        var snapshot: PromptHistorySnapshot?
        report.append("snapshot (dedupe + sort + fold): \(Self.seconds { snapshot = PromptHistorySnapshot(records: loaded.values) }) s, entries: \(snapshot?.count ?? 0)")

        for query in ["fix", "зроби", "release", "commit", "zzqqxx-nothing", "пошук по промптах"] {
            var hits = 0
            let time = Self.seconds { for _ in 0..<10 { hits = snapshot?.search(query).count ?? 0 } } / 10
            report.append("search \"\(query)\": \(String(format: "%.2f", time * 1000)) ms, \(hits) hits")
        }

        // Pre-filter check: every line decoded, nothing skipped.
        var full = 0
        let fullTime = Self.seconds {
            for path in cold.records.keys {
                JSONLReader.forEachJSONObject(in: URL(fileURLWithPath: path)) { object in
                    if UserPromptExtractor.prompt(from: object) != nil { full += 1 }
                    return true
                }
            }
        }
        report.append("unfiltered decode of the same files: \(fullTime) s, prompts: \(full)")

        let text = report.joined(separator: "\n")
        print(text)
        if let reportPath = Self.reportPath { try text.write(toFile: reportPath, atomically: true, encoding: .utf8) }
        #expect(full == indexed)
    }
}
