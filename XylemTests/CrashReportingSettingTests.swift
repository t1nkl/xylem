//
//  CrashReportingSettingTests.swift
//  XylemTests
//
//  "Send crash reports" is read before `registerDefaults()` (Sentry starts
//  first), so an unset key must mean on, and string values ("NO" from
//  `defaults write` or a launch argument) must count.
//

import Testing
import Foundation

@MainActor
struct CrashReportingSettingTests {
    private let key = AppSettings.Keys.sendCrashReports

    @Test func unsetMeansOnAndStoredValuesAreHonoured() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }

        defaults.removeObject(forKey: key)
        #expect(AppSettings.sendCrashReports)
        defaults.set(false, forKey: key)
        #expect(!AppSettings.sendCrashReports)
        defaults.set("NO", forKey: key)
        #expect(!AppSettings.sendCrashReports)
        defaults.set(true, forKey: key)
        #expect(AppSettings.sendCrashReports)
    }
}
