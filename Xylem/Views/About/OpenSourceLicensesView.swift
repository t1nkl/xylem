//
//  OpenSourceLicensesView.swift
//  Xylem
//
//  Xylem's own license and every third-party library shipped inside
//  Xylem.app, with their full license texts, shown by the About window
//  (License and Libraries; Help > Open-Source Licenses opens Libraries).
//
//  The texts are verbatim copies of the packages' LICENSE files, bundled
//  from Xylem/Licenses/. A new package linked into the app needs a row here
//  and its license file there. Packages that never reach the macOS app
//  (SwiftTerm's swift-png and swift-argument-parser) are not listed.
//

import SwiftUI

struct OpenSourceLibrary: Identifiable, Equatable {
    var id: String { name }
    let name: String
    /// What it does in Xylem, one plain sentence.
    let purpose: String
    let license: String
    let website: String
    /// Bundled resource (Xylem/Licenses/<file>.txt).
    let licenseFile: String

    /// Xylem itself, shown above the libraries.
    static let xylem = OpenSourceLibrary(
        name: "Xylem",
        purpose: "\(AboutPanel.copyright()). Xylem is free software: you can redistribute it and/or modify it under the GNU General Public License, version 3. It comes with no warranty; the full terms are below.",
        license: "GNU GPL v3",
        website: "github.com/t1nkl/xylem",
        licenseFile: "Xylem-LICENSE"
    )

    static let all: [OpenSourceLibrary] = [
        OpenSourceLibrary(
            name: "SwiftTerm",
            purpose: "The terminal in every tab.",
            license: "MIT License",
            website: "github.com/migueldeicaza/SwiftTerm",
            licenseFile: "SwiftTerm-LICENSE"
        ),
        OpenSourceLibrary(
            name: "Sparkle",
            purpose: "Checks for, downloads and installs updates.",
            license: "MIT License, with BSD and zlib parts",
            website: "github.com/sparkle-project/Sparkle",
            licenseFile: "Sparkle-LICENSE"
        ),
        OpenSourceLibrary(
            name: "Sentry SDK",
            purpose: "Sends crash reports.",
            license: "MIT License",
            website: "github.com/getsentry/sentry-cocoa",
            licenseFile: "Sentry-LICENSE"
        ),
        OpenSourceLibrary(
            name: "highlight.js",
            purpose: "Colours the code in the Files and Changes drawer.",
            license: "BSD 3-Clause License",
            website: "github.com/highlightjs/highlight.js",
            licenseFile: "highlight.js-LICENSE"
        ),
    ]

    func licenseText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: licenseFile, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var websiteURL: URL? { URL(string: "https://" + website) }
}

/// The Help menu item. A View so it can read `openWindow`.
struct OpenSourceLicensesMenuItem: View {
    let aboutModel: AboutWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open-Source Licenses") {
            AboutWindowOpener(model: aboutModel, openWindow: openWindow)(.libraries)
        }
    }
}
