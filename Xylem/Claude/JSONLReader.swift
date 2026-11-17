//
//  JSONLReader.swift
//  Xylem
//
//  Stream-reads `.jsonl` files line by line so huge transcripts don't have
//  to be loaded into memory all at once. The caller decides when to stop by
//  returning `false` from the handler.
//
//  `nonisolated`: the target defaults to MainActor isolation, and this is
//  pure file I/O that must never run on the main thread.
//

import Foundation

nonisolated enum JSONLReader {
    /// Reads `url` line by line, decoding each non-empty line as JSON, and
    /// invokes `handler` with the resulting `[String: Any]`. The iteration
    /// stops when `handler` returns `false`.
    /// - Returns: number of lines visited (not necessarily parsed).
    @discardableResult
    static func forEachJSONObject(
        in url: URL,
        maxBytes: Int = .max,
        handler: ([String: Any]) -> Bool
    ) -> Int {
        guard let handle = SafeFileRead.handle(url) else { return 0 }
        defer { try? handle.close() }

        var visited = 0
        let result = scanLines(from: handle, maxBytes: maxBytes) { line in
            visited += 1
            guard let obj = decode(line), !obj.isEmpty else { return true }
            return handler(obj)
        }
        if case let .reachedEOF(trailing) = result,
           let obj = decode(trailing), !obj.isEmpty {
            _ = handler(obj)
        }
        return visited
    }

    /// Incremental variant: starts reading at byte `offset` and hands every
    /// complete JSON line after it to `handler`.
    ///
    /// A trailing line without a newline is consumed only if it already
    /// decodes as JSON (a finished record whose `\n` hasn't landed yet);
    /// a half-written line is left for the next call.
    /// - Returns: the byte offset just past the last consumed line, or `nil`
    ///   if the file could not be opened or seeked.
    static func forEachJSONObject(
        in url: URL,
        fromOffset offset: UInt64,
        handler: ([String: Any]) -> Void
    ) -> UInt64? {
        guard let handle = SafeFileRead.handle(url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }

        var consumed: UInt64 = 0
        let result = scanLines(from: handle, maxBytes: .max) { line in
            consumed += UInt64(line.count) + 1
            if let obj = decode(line), !obj.isEmpty { handler(obj) }
            return true
        }
        if case let .reachedEOF(trailing) = result,
           !trailing.isEmpty,
           let obj = decode(trailing) {
            consumed += UInt64(trailing.count)
            if !obj.isEmpty { handler(obj) }
        }
        return offset + consumed
    }

    // MARK: - Private

    private enum ScanResult {
        case stopped
        case reachedEOF(trailing: Data)
        case reachedByteLimit
    }

    /// Splits the stream on `\n`. Each newline search covers only the bytes
    /// appended since the previous search, and consumed lines are dropped
    /// once per chunk, so long lines (big tool results) stay linear.
    private static func scanLines(
        from handle: FileHandle,
        maxBytes: Int,
        line: (Data) -> Bool
    ) -> ScanResult {
        let chunkSize = 256 * 1024
        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        var bytesRead = 0

        while bytesRead < maxBytes {
            let next = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk = next, !chunk.isEmpty else {
                return .reachedEOF(trailing: buffer)
            }
            bytesRead += chunk.count

            // `buffer` is always rebuilt zero-based, so offsets are indices.
            var searchFrom = buffer.count
            buffer.append(chunk)
            var lineStart = 0

            while let newlineIndex = buffer[searchFrom...].firstIndex(of: newline) {
                if !line(buffer[lineStart..<newlineIndex]) { return .stopped }
                lineStart = newlineIndex + 1
                searchFrom = lineStart
            }
            if lineStart > 0 {
                buffer = lineStart < buffer.count ? Data(buffer[lineStart...]) : Data()
            }
        }
        return .reachedByteLimit
    }

    private static func decode(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
