//
//  OpenSourceLicensesTests.swift
//  XylemTests
//
//  Xylem and every library in Help > Open-Source Licenses have their license text
//  bundled (the synchronized Xylem folder copies Xylem/Licenses/ into the
//  app and into this test bundle alike).
//

import Foundation
import Testing

private final class BundleMarker {}

struct OpenSourceLicensesTests {
    private let bundle = Bundle(for: BundleMarker.self)

    @Test func everyLibraryHasItsLicenseText() {
        for library in [OpenSourceLibrary.xylem] + OpenSourceLibrary.all {
            let text = library.licenseText(in: bundle)
            #expect(text != nil, "\(library.name): \(library.licenseFile).txt not bundled")
            #expect(text?.contains("Copyright") == true, "\(library.name)")
        }
    }

    @Test func sparkleTextKeepsTheThirdPartyNotices() throws {
        let sparkle = try #require(OpenSourceLibrary.all.first { $0.name == "Sparkle" })
        let text = try #require(sparkle.licenseText(in: bundle))
        for part in ["bsdiff", "sais-lite", "Ed25519", "SUSignatureVerifier"] {
            #expect(text.contains(part), "\(part)")
        }
    }
}
