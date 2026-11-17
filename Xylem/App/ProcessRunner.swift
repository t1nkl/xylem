//
//  ProcessRunner.swift
//  Xylem
//
//  Runs a short-lived tool (git, ps) and waits for it with a time limit.
//  Output goes to private temp files, not pipes: reading a pipe to its end
//  also waits for any process the tool left behind holding it (a daemon
//  started by a git hook), which no time limit could stop. Only the tool
//  itself is waited for. Blocking: call it from a GCD queue, not the
//  cooperative pool.
//

import Foundation

nonisolated enum ProcessRunner {
    struct Result {
        /// Exit status; meaningful when `exited`.
        let status: Int32
        /// Ended by `exit`, not by a signal.
        let exited: Bool
        /// Stopped because it ran past the limit.
        let timedOut: Bool
        let output: Data
        /// Empty unless `captureErrors`.
        let errors: Data
    }

    /// nil when the tool couldn't be started (or the temp files made).
    static func run(
        _ executable: String,
        _ arguments: [String],
        in directory: String? = nil,
        captureErrors: Bool = false,
        timeout: TimeInterval
    ) -> Result? {
        guard let output = TempOutput() else { return nil }
        var errors: TempOutput?
        if captureErrors {
            guard let file = TempOutput() else { return nil }
            errors = file
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardOutput = output.handle
        process.standardError = errors?.handle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        return Result(
            status: process.isRunning ? -1 : process.terminationStatus,
            exited: !process.isRunning && process.terminationReason == .exit,
            timedOut: timedOut,
            output: output.read(),
            errors: errors?.read() ?? Data()
        )
    }

    /// A 0600 file in the temp folder, deleted with this value.
    private final class TempOutput {
        let url: URL
        let handle: FileHandle

        init?() {
            url = FileManager.default.temporaryDirectory.appending(path: "xylem-run-\(UUID().uuidString).out")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: url)
            else { return nil }
            self.handle = handle
        }

        func read() -> Data { (try? Data(contentsOf: url)) ?? Data() }

        deinit {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }
}
