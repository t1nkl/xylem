//
//  UncheckedSendable.swift
//  Xylem
//
//  Carries a reader existential (`any SessionStatsReading`, …) into a `@concurrent`
//  function. The production readers are stateless `nonisolated` structs, but
//  the protocols can't require `Sendable` without forcing every conformer
//  (preview fixtures included) to be nonisolated too.
//

nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
