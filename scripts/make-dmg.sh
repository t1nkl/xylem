#!/bin/zsh
#
# Build a signed, notarised, stapled DMG for Xylem.
#
# Prereqs (one-time):
#   - "Developer ID Application" cert in Keychain
#   - `xcrun notarytool store-credentials xylem-notary` once, using an
#     app-specific password generated at appleid.apple.com.
#
# Per-release flow (run from repo root):
#   scripts/make-dmg.sh v0.1
#
# Produces /tmp/Xylem-<version>.dmg - hand that file to anyone on macOS.
#
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $(basename "$0") <version>   e.g. v0.1" >&2
  exit 1
fi

SCHEME=Xylem
PROJECT=Xylem.xcodeproj
TEAM_ID="${XYLEM_TEAM_ID:-CSXZ24ZYDY}"
# The Developer ID certificate of that team, found in the Keychain by its
# SHA-1 (XYLEM_SIGNING_IDENTITY overrides it with a hash or a name).
IDENTITY="${XYLEM_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -v team="(${TEAM_ID})" '/"Developer ID Application: / && index($0, team) { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
  echo "no \"Developer ID Application\" certificate for team ${TEAM_ID} in the Keychain" >&2
  exit 1
fi
NOTARY_PROFILE=xylem-notary

ARCHIVE=/tmp/XylemArchive-${VERSION}.xcarchive
EXPORT_DIR=/tmp/XylemExport-${VERSION}
EXPORT_OPTIONS=/tmp/XylemExportOptions-${VERSION}.plist
APP=${EXPORT_DIR}/Xylem.app
STAGE=/tmp/XylemDMGStage-${VERSION}
DMG=/tmp/Xylem-${VERSION}.dmg
VOLNAME="Xylem ${VERSION}"

# -- 1. archive -----------------------------------------------------------
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE" "$DMG"
echo "▸ Archiving Release build…"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  >/dev/null

# Keep the archive (with its dSYMs) where Xcode's Organizer looks: crash
# reports from this version can only be symbolicated with these files,
# and /tmp doesn't survive a reboot.
KEEP_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
mkdir -p "$KEEP_DIR"
rm -rf "$KEEP_DIR/Xylem ${VERSION}.xcarchive"
cp -R "$ARCHIVE" "$KEEP_DIR/Xylem ${VERSION}.xcarchive"
echo "▸ Archive + dSYMs kept in $KEEP_DIR/Xylem ${VERSION}.xcarchive"

# Send the dSYMs to Sentry, or crash reports show addresses instead of our
# function names. Token, org and project live in the git-ignored
# .sentryclirc in the repo root (never committed). Without it the release
# goes on: the archive above keeps the files for a later upload.
if command -v sentry-cli >/dev/null && [[ -f .sentryclirc ]]; then
  echo "▸ Uploading dSYMs to Sentry…"
  if sentry-cli debug-files upload "$ARCHIVE/dSYMs" >/tmp/xylem-sentry-dsyms.log 2>&1; then
    echo "▸ dSYMs uploaded"
  else
    echo "⚠︎ dSYM upload failed (see /tmp/xylem-sentry-dsyms.log) - retry later with:"
    echo "  sentry-cli debug-files upload \"$KEEP_DIR/Xylem ${VERSION}.xcarchive/dSYMs\""
  fi
else
  echo "⚠︎ sentry-cli or .sentryclirc missing - dSYMs not uploaded (they are in the kept archive)"
fi

# -- 2. export signed .app ------------------------------------------------
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>            <string>developer-id</string>
    <key>teamID</key>            <string>${TEAM_ID}</string>
    <key>signingStyle</key>      <string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    <key>destination</key>       <string>export</string>
</dict>
</plist>
PLIST

echo "▸ Exporting signed .app…"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" >/dev/null

# Sparkle's own texts use an unspaced em dash (U+2014 with no spaces: "is now available<dash>you have");
# Xylem's rule is " - ". Patch its strings, then re-sign the framework and
# the app (the helpers inside keep their export signatures).
CHANGED=$(python3 scripts/sparkle-strings.py "$APP")
echo "▸ Sparkle strings: $CHANGED em dashes replaced"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --preserve-metadata=entitlements,requirements,flags "$APP"
codesign --verify --deep --strict "$APP"

# -- 3. notarise the .app -------------------------------------------------
APP_ZIP=/tmp/Xylem-${VERSION}-app.zip
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP" "$APP_ZIP"

echo "▸ Submitting .app to Apple (this can take 5-30 min)…"
xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling ticket onto .app…"
xcrun stapler staple "$APP"

# -- 4. build DMG from the stapled .app -----------------------------------
echo "▸ Building DMG…"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/Xylem.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

codesign --force --sign "$IDENTITY" "$DMG"

# -- 5. notarise and staple the DMG --------------------------------------
echo "▸ Submitting DMG to Apple…"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# -- 6. verify ------------------------------------------------------------
echo ""
echo "=== signature ==="
codesign --verify --verbose=2 "$DMG"
echo ""
echo "=== gatekeeper ==="
spctl -a -t open --context context:primary-signature -vvv "$DMG" || true
echo ""
echo "=== stapled ticket ==="
xcrun stapler validate "$DMG"
echo ""
echo "▸ Done: $DMG ($(du -h "$DMG" | cut -f1))"
