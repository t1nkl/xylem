//
//  OpenSourceLicensesView.swift
//  Xylem
//
//  Help > Open-Source Licenses: Xylem's own license (GPL v3, which asks an
//  interactive program to show its notice) and every third-party library
//  shipped inside Xylem.app with its full license text (MIT/BSD/zlib
//  require the notice in the app or its documentation). The About window only lists the
//  names and points here - the full texts didn't fit its small credits box.
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

struct OpenSourceLicensesView: View {
    var libraries: [OpenSourceLibrary] = OpenSourceLibrary.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LibraryLicenseSection(library: .xylem)
                Text("Xylem is built with these open-source libraries, each used under the license below.")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                ForEach(libraries) { library in
                    LibraryLicenseSection(library: library)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(AppTheme.Colors.background)
        .preferredColorScheme(.dark)
    }
}

private struct LibraryLicenseSection: View {
    let library: OpenSourceLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(library.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(library.license)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textMuted)
                Spacer(minLength: 12)
                if let url = library.websiteURL {
                    Link(library.website, destination: url)
                        .font(.system(size: 12))
                }
            }
            Text(library.purpose)
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(library.licenseText() ?? "License text missing from this build.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.Colors.panelBackgroundRaised)
                )
                .padding(.top, 4)
        }
    }
}

/// The Help menu item. A View so it can read `openWindow`.
struct OpenSourceLicensesMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open-Source Licenses") {
            openWindow(id: OpenSourceLicensesView.windowID)
        }
    }
}

extension OpenSourceLicensesView {
    static let windowID = "open-source-licenses"
}
