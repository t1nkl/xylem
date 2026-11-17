//
//  TimestampParser.swift
//  Xylem
//
//  ISO-8601 parser that accepts both fractional-second and plain second
//  precision. Claude Code currently writes timestamps with milliseconds but
//  we shouldn't break if that changes.
//

import Foundation

nonisolated enum TimestampParser {
    // ISO8601DateFormatter is thread-safe; it just is not annotated Sendable.
    nonisolated(unsafe) private static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        if let date = withFractions.date(from: string) { return date }
        return plain.date(from: string)
    }
}
