//
//  CrashReporting.swift
//  Xylem
//
//  Crash reports through Sentry - crashes and hangs only. Xylem shows the
//  user's prompts, paths and project names everywhere, so nothing that
//  could carry them is collected: no breadcrumbs (they would hold console
//  lines and UI actions), no tracing, no network capture, no default PII
//  (IP, host name). An event is the stack trace plus OS, model and app
//  version.
//
//  Off when the user unticks Settings → Updates & Privacy → "Send crash reports"
//  (read once here, so the switch applies at the next launch).
//
//  Release builds only: Debug runs and Xcode Previews (whose hosts crash
//  by design) would flood the project. And only the official bundle id: a
//  fork built from this source (which must use its own id) doesn't report
//  into this project.
//

import Foundation
import Sentry

enum CrashReporting {
    /// Public by design: a DSN only lets a client send events.
    private static let officialBundleID = "com.t1nkl.Xylem"
    private static let dsn = "https://becbb7866c02b237145761c2aafd9bc2@o4504968911126528.ingest.us.sentry.io/4512432272834560"

    static func start() {
        #if !DEBUG
        guard AppSettings.sendCrashReports,
              Bundle.main.bundleIdentifier == officialBundleID else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.maxBreadcrumbs = 0
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.enableLogs = false
            options.enableAppHangTracking = true
            options.enableUncaughtNSExceptionReporting = true
            options.beforeSend = { event in
                // The Mac's name (often the user's name) - not needed to read a crash.
                event.serverName = nil
                event.user = nil
                return event
            }
        }
        #endif
    }
}
