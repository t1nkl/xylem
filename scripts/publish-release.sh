#!/bin/zsh
#
# Publish a DMG built by make-dmg.sh:
#   1. GitHub release <version> in t1nkl/xylem (the tag must be pushed):
#      title, notes and Xylem-<version>.dmg - what users and Sparkle download.
#   2. Check the asset downloads without signing in and matches.
#   3. Add the version to docs/appcast.xml (GitHub Pages serves docs/)
#      - only now, so no client sees an update whose file isn't there yet.
#      The commit is made in a fresh clone and pushed; `git pull` afterwards.
#   4. Wait until Pages serves the new appcast.
#
# Safe to re-run: an existing release gets the asset replaced and notes
# updated; the appcast item of the same build is replaced, not duplicated.
#
# Prereqs: gh logged in as t1nkl; the Sparkle EdDSA key in the Keychain
# (account "xylem", created by Sparkle's generate_keys); release notes in
# release-notes/<version>.md (### New / ### Improved / ### Fixed).
#
#   scripts/make-dmg.sh v0.10.0 && scripts/publish-release.sh v0.10.0
#
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $(basename "$0") <version>   e.g. v0.10.0" >&2
  exit 1
fi

REPO=t1nkl/xylem
APPCAST_URL=https://t1nkl.github.io/xylem/appcast.xml
SPARKLE_ACCOUNT=xylem
BUNDLE_ID=com.t1nkl.Xylem
DMG=/tmp/Xylem-${VERSION}.dmg
NOTES=release-notes/${VERSION}.md
ASSET_URL=https://github.com/${REPO}/releases/download/${VERSION}/Xylem-${VERSION}.dmg

die() { echo "✗ $*" >&2; exit 1; }

# -- 0. preconditions -----------------------------------------------------
[[ -f "$DMG" ]] || die "$DMG not found - run scripts/make-dmg.sh $VERSION first"
[[ -f "$NOTES" ]] || die "$NOTES not found - write the release notes first"
gh auth status >/dev/null 2>&1 || die "gh is not logged in"
gh api "repos/${REPO}/git/ref/tags/${VERSION}" >/dev/null 2>&1 \
  || die "tag $VERSION is not in $REPO - tag and push first"
gh api "repos/${REPO}/pages" >/dev/null 2>&1 \
  || die "GitHub Pages is off in $REPO (Settings > Pages > main / docs) - the appcast would never go live"

# A zsh glob, not `ls`: with CLICOLOR_FORCE set, ls wraps the path in
# colour codes.
if [[ -z "${SPARKLE_BIN:-}" ]]; then
  SPARKLE_CANDIDATES=(~/Library/Developer/Xcode/DerivedData/Xylem-*/SourcePackages/artifacts/sparkle/Sparkle/bin(N/))
  SPARKLE_BIN="${SPARKLE_CANDIDATES[1]:-}"
fi
[[ -x "$SPARKLE_BIN/sign_update" ]] \
  || die "Sparkle tools not found - open the project in Xcode once, or set SPARKLE_BIN"

# What is inside the DMG decides the appcast entry, not the argument.
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MNT" >/dev/null 2>&1 || true' EXIT
PLIST="$MNT/Xylem.app/Contents/Info.plist"
SHORT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")
FEED=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$PLIST" 2>/dev/null || true)
hdiutil detach "$MNT" >/dev/null
trap - EXIT
rmdir "$MNT" 2>/dev/null || true
[[ "v$SHORT" == "$VERSION" ]] || die "DMG holds $SHORT, not $VERSION"
[[ "$BID" == "$BUNDLE_ID" ]] || die "DMG holds bundle id $BID"
[[ "$FEED" == "$APPCAST_URL" ]] || die "DMG's SUFeedURL is '$FEED'"

echo "▸ $VERSION (build $BUILD, macOS $MIN_OS+)"

# -- 1. EdDSA signature ---------------------------------------------------
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
# -> sparkle:edSignature="…" length="…"
[[ "$SIGNATURE" == *'sparkle:edSignature="'* ]] || die "sign_update failed: $SIGNATURE"

# -- 2. release -----------------------------------------------------------
if gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1; then
  echo "▸ $REPO: release exists, replacing asset and notes"
  gh release upload "$VERSION" "$DMG" -R "$REPO" --clobber
  gh release edit "$VERSION" -R "$REPO" --title "$VERSION" --notes-file "$NOTES" >/dev/null
else
  echo "▸ $REPO: creating release"
  gh release create "$VERSION" "$DMG" -R "$REPO" --title "$VERSION" --notes-file "$NOTES" --verify-tag >/dev/null
fi

# -- 3. the file is really there -----------------------------------
echo "▸ Checking the download…"
LOCAL_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
FETCHED=$(mktemp)
DOWNLOADED=0
for attempt in 1 2 3 4 5 6; do
  if curl -fsSL -o "$FETCHED" "$ASSET_URL"; then DOWNLOADED=1; break; fi
  sleep 10
done
(( DOWNLOADED )) || { rm -f "$FETCHED"; die "couldn't download $ASSET_URL"; }
REMOTE_SHA=$(shasum -a 256 "$FETCHED" | cut -d' ' -f1)
rm -f "$FETCHED"
[[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] || die "downloaded asset doesn't match the DMG ($REMOTE_SHA)"

# -- 4. appcast -----------------------------------------------------------
echo "▸ Updating appcast.xml…"
WORK=$(mktemp -d)
gh repo clone "$REPO" "$WORK" -- -q --depth 1
GH_ID=$(gh api user --jq .id)
python3 - "$WORK/docs/appcast.xml" "$NOTES" "$VERSION" "$SHORT" "$BUILD" "$MIN_OS" "$ASSET_URL" "$SIGNATURE" <<'PY'
import sys, re, email.utils, html
path, notes_path, version, short, build, min_os, url, signature = sys.argv[1:]
feed = open(path, encoding="utf-8").read()
notes = open(notes_path, encoding="utf-8").read().strip()
assert "]]>" not in notes, "release notes can't contain ]]>"
item = f"""    <item>
      <title>{html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{short}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_os}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[
{notes}
]]></description>
      <enclosure url="{url}" type="application/octet-stream" {signature}/>
    </item>
"""
# Re-running replaces this build's item instead of adding a second one.
feed = re.sub(r"    <item>\n(?:(?!</item>).)*?<sparkle:version>" + re.escape(build) + r"</sparkle:version>.*?</item>\n",
              "", feed, flags=re.S)
marker = "    <!-- items: newest first -->\n"
assert marker in feed, "appcast.xml lost its items marker"
feed = feed.replace(marker, marker + item, 1)
open(path, "w", encoding="utf-8").write(feed)
PY
xmllint --noout "$WORK/docs/appcast.xml" || die "appcast.xml is not valid XML"
if git -C "$WORK" diff --quiet; then
  echo "▸ appcast.xml unchanged"
else
  git -C "$WORK" -c user.name=t1nkl -c "user.email=${GH_ID}+t1nkl@users.noreply.github.com" \
    commit -qam "appcast: ${VERSION} (build ${BUILD})"
  git -C "$WORK" push -q
fi
rm -rf "$WORK"

# -- 5. Pages serves it ----------------------------------------------------
echo "▸ Waiting for GitHub Pages…"
SERVED=$(mktemp)
for attempt in $(seq 1 30); do
  # To a file, not a pipe: grep -q quits at the first match and, under
  # pipefail, curl's SIGPIPE would read as a failure once the feed is big.
  if curl -fsSL -o "$SERVED" "${APPCAST_URL}?t=$(date +%s)" \
    && grep -q "<sparkle:version>${BUILD}</sparkle:version>" "$SERVED"; then
    rm -f "$SERVED"
    echo "▸ Done: $VERSION is live - $ASSET_URL (git pull for the appcast commit)"
    exit 0
  fi
  sleep 10
done
die "Pages didn't serve build $BUILD within 5 min - check the Pages build in $REPO"
