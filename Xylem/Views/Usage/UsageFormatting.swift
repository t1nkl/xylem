//
//  UsageFormatting.swift
//  Xylem
//
//  Small formatting helpers shared between the dashboard's tables and
//  summary tiles. Kept free-standing so views stay declarative.
//

import Foundation

enum UsageFormatting {
    static func money(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "$%.2f", amount)
                .replacingOccurrences(of: ",", with: "")
                .applyingThousandsSeparators()
        }
        return String(format: "$%.2f", amount)
    }

    /// "incl. $12.34 subagents", or nil when subagents spent nothing that
    /// rounds to a cent.
    static func subagentShare(_ amount: Double?) -> String? {
        guard let amount, amount >= 0.005 else { return nil }
        return "incl. \(money(amount)) subagents"
    }

    /// Total Cost caption: the subagents' share and the part priced by a
    /// fallback rate (models without a listed price), whichever apply.
    static func costCaption(_ totals: UsageTotals) -> String? {
        var parts: [String] = []
        if let subagents = subagentShare(totals.subagentCostUSD) { parts.append(subagents) }
        if totals.estimatedCostUSD >= 0.005 { parts.append("\(money(totals.estimatedCostUSD)) estimated") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact form for a table row: "agents $1.23".
    static func subagentAmount(_ amount: Double) -> String? {
        guard amount >= 0.005 else { return nil }
        return "agents \(money(amount))"
    }

    static func integer(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func compactTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000     { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }
}

private extension String {
    func applyingThousandsSeparators() -> String {
        let parts = split(separator: ".")
        guard let whole = parts.first else { return self }
        let fractional = parts.count > 1 ? "." + parts[1] : ""

        var digits = String(whole)
        let hasDollarPrefix = digits.hasPrefix("$")
        if hasDollarPrefix { digits.removeFirst() }

        var result = ""
        for (index, char) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { result = "," + result }
            result = String(char) + result
        }
        return (hasDollarPrefix ? "$" : "") + result + fractional
    }
}
