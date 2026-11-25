//
//  AboutWindowView.swift
//  Xylem
//
//  Xylem > About Xylem: the app icon, version and the Claude Code version
//  the tabs run on the left; the tagline, copyright, links and three
//  sections on the right - License (Xylem's GPL v3 notice, which an
//  interactive program has to show, and the full text), Libraries (every
//  library shipped inside Xylem.app with its full license text, which
//  MIT/BSD/zlib require in the app) and What's New (this version's release
//  notes). Help > Open-Source Licenses opens it on Libraries.
//

import AppKit
import SwiftUI

enum AboutSection: String, CaseIterable, Identifiable {
    case license = "License"
    case libraries = "Libraries"
    case whatsNew = "What's New"

    var id: String { rawValue }
}

/// Which section the About window shows; the Help menu item opens it on Libraries.
@Observable
final class AboutWindowModel {
    var section: AboutSection = .license
}

enum AboutInfo {
    static let tagline = "Every Claude Code session in sight"
    static let githubURL = URL(string: "https://github.com/t1nkl/xylem")!
    static let websiteURL = URL(string: "https://xylem.t1nkl.dev")!

    static let licenseNotice = """
    Xylem is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3 of the License.

    Xylem is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
    """

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// This version's release notes, copied into the app at build time from
    /// release-notes/v<version>.md (nil in a build without them).
    static func releaseNotes(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "ReleaseNotes", withExtension: "md"),
              let text = SafeFileRead.string(url)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func releaseURL(version: String) -> URL? {
        URL(string: "https://github.com/t1nkl/xylem/releases/tag/v\(version)")
    }
}

struct AboutWindowView: View {
    let updater: AppUpdater
    @Bindable var model: AboutWindowModel
    @State private var showFullLicense = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            identityColumn
            VStack(alignment: .leading, spacing: 0) {
                Text(AboutInfo.tagline)
                    .font(.system(size: 20, weight: .semibold))
                Text("\(AboutPanel.copyright()) · Free and open source")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                HStack(spacing: 8) {
                    Button { openURL(AboutInfo.githubURL) } label: {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .help(AboutInfo.githubURL.absoluteString)
                    Button { openURL(AboutInfo.websiteURL) } label: {
                        Label("Website", systemImage: "globe")
                    }
                    .help(AboutInfo.websiteURL.absoluteString)
                }
                .controlSize(.small)
                .padding(.top, 12)
                Picker("Section", selection: $model.section) {
                    ForEach(AboutSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 20)
                .padding(.bottom, 14)
                sectionContent
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 700, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .onChange(of: model.section) { showFullLicense = false }
    }

    private var identityColumn: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)
            Text("Xylem")
                .font(.system(size: 28, weight: .light))
                .padding(.top, 8)
            Text("\(AboutInfo.version) Build \(AboutInfo.build)")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let claude = ClaudeCLIVersion.known {
                Text("Claude Code \(claude)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Check for Updates…") { updater.checkForUpdates() }
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
                .padding(.bottom, 26)
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.18))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.section {
        case .license: licenseSection
        case .libraries: AboutLibrariesList()
        case .whatsNew: AboutWhatsNew()
        }
    }

    private var licenseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showFullLicense {
                ScrollView {
                    Text(OpenSourceLibrary.xylem.licenseText() ?? "License text missing from this build.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(AboutInfo.licenseNotice)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button(showFullLicense ? "Show Summary" : "Read the Full License") { showFullLicense.toggle() }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }
}

/// Libraries: what each one does, its license and a disclosure with the full text.
private struct AboutLibrariesList: View {
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Xylem is built with these open-source libraries, each used under its license.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ForEach(OpenSourceLibrary.all) { library in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(library.name).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text(library.license).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(library.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            if let url = library.websiteURL {
                                Link(library.website, destination: url).font(.system(size: 11))
                            }
                            Button(expanded.contains(library.id) ? "Hide License" : "Show License") {
                                if expanded.contains(library.id) { expanded.remove(library.id) } else { expanded.insert(library.id) }
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                        if expanded.contains(library.id) {
                            Text(library.licenseText() ?? "License text missing from this build.")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What's New: this version's release notes, or a link to them.
private struct AboutWhatsNew: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Xylem \(AboutInfo.version)").font(.system(size: 13, weight: .semibold))
                if let notes = AboutInfo.releaseNotes() {
                    ForEach(Array(ReleaseNotes(markdown: notes).sections.enumerated()), id: \.offset) { _, section in
                        if let title = section.title {
                            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                Text(WhatsNewSheet.inline(item))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if let url = AboutInfo.releaseURL(version: AboutInfo.version) {
                    Link("Release notes on GitHub", destination: url).font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Opens the About window, optionally on a section; for menu items (a View can read `openWindow`).
struct AboutWindowOpener {
    let model: AboutWindowModel
    let openWindow: OpenWindowAction

    func callAsFunction(_ section: AboutSection? = nil) {
        if let section { model.section = section }
        NSApp.activate()
        openWindow(id: AboutWindowView.windowID)
    }
}

extension AboutWindowView {
    static let windowID = "about"
}
