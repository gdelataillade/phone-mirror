#!/bin/bash
# Cuts a signed, notarized release: builds, notarizes the app and DMG, signs
# the Sparkle update zip, appends an appcast entry, publishes a GitHub
# Release, and commits the version bump + appcast. Run from a clean working
# tree on the branch you want to release from.
#
# One-time setup this script depends on and cannot do for you:
#   1. A "Developer ID Application" certificate in your login keychain.
#      Xcode > Settings > Accounts > your team > Manage Certificates > + >
#      Developer ID Application.
#   2. Notarization credentials stored under the profile name below:
#      xcrun notarytool store-credentials iPhoneMirror-notary \
#        --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
#      (Create the app-specific password at appleid.apple.com; team ID is in
#      developer.apple.com/account.)
#   3. The Sparkle signing key already exists in your login keychain (it
#      does — see Resources/Info.plist's SUPublicEDKey, account "iPhoneMirror").
#      The FIRST time anything actually uses that key to sign a file, macOS
#      shows a one-time Keychain access prompt that blocks forever if nothing
#      is there to click it — including this script, run non-interactively.
#      Clear that prompt once, interactively, before running this script:
#        echo hi > /tmp/warm.txt && zip /tmp/warm.zip /tmp/warm.txt
#        SPARKLE_SIGN=.build/artifacts/sparkle/Sparkle/bin/sign_update
#        "$SPARKLE_SIGN" --account iPhoneMirror /tmp/warm.zip
#      Click "Always Allow" on the dialog that appears, then delete the temp files.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if [ -z "$version" ]; then
    echo "Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.2.0" >&2
    exit 1
fi

notary_profile="iPhoneMirror-notary"
sparkle_account="iPhoneMirror"
repo="gdelataillade/phone-mirror"

# --- Preflight: fail fast, before touching anything ---
identity="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^[^"]*"([^"]*)".*/\1/' || true)"
if [ -z "$identity" ]; then
    echo "No 'Developer ID Application' certificate in the keychain. See the setup notes at the top of this script." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    echo "No notarization credentials under keychain profile '$notary_profile'. See the setup notes at the top of this script." >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "gh CLI is not installed or not authenticated. Run: gh auth login" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean. Commit or stash first." >&2
    exit 1
fi
sign_update="$(find .build -path "*/Sparkle/bin/sign_update" | head -1)"
if [ -z "$sign_update" ]; then
    echo "Could not locate Sparkle's sign_update under .build/. Run scripts/build.sh once first to resolve dependencies." >&2
    exit 1
fi

echo "Releasing iPhoneMirror $version, signing with: $identity"

# --- Version bump ---
previous_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)"
next_build=$((previous_build + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_build" Resources/Info.plist
echo "Version: $version (build $next_build, was $previous_build)"

# --- Signed build ---
CODESIGN_IDENTITY="$identity" ./scripts/build.sh
app="$PWD/build/iPhoneMirror.app"

# --- Notarize and staple the app ---
app_zip="$PWD/build/iPhoneMirror-$version.app.zip"
rm -f "$app_zip"
ditto -c -k --keepParent "$app" "$app_zip"
echo "Submitting app for notarization (this can take a few minutes)…"
xcrun notarytool submit "$app_zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
rm -f "$app_zip"

# --- DMG: build, sign, notarize, staple ---
dmg_stage="$PWD/build/dmg-stage"
rm -rf "$dmg_stage"
mkdir -p "$dmg_stage"
cp -R "$app" "$dmg_stage/"
ln -s /Applications "$dmg_stage/Applications"
dmg="$PWD/build/iPhoneMirror-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "iPhoneMirror" -srcfolder "$dmg_stage" -ov -format UDZO "$dmg"
rm -rf "$dmg_stage"
codesign --force --sign "$identity" "$dmg"
echo "Submitting DMG for notarization…"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"

# --- Sparkle enclosure: re-zip the now-stapled app, sign it ---
update_zip="$PWD/build/iPhoneMirror-$version.zip"
rm -f "$update_zip"
ditto -c -k --keepParent "$app" "$update_zip"
sign_output="$("$sign_update" --account "$sparkle_account" "$update_zip")"
echo "$sign_output"
ed_signature="$(echo "$sign_output" | grep -oE 'sparkle:edSignature="[^"]*"' | head -1 | cut -d'"' -f2)"
enclosure_length="$(echo "$sign_output" | grep -oE 'length="[^"]*"' | head -1 | cut -d'"' -f2)"
if [ -z "$ed_signature" ] || [ -z "$enclosure_length" ]; then
    echo "Could not parse an EdDSA signature/length out of sign_update's output; not touching the appcast." >&2
    exit 1
fi

# --- Publish the GitHub Release first, so the appcast enclosure URL is live ---
release_notes="Release $version. See VALIDATION.md and the commit history for details."
gh release create "v$version" "$dmg" "$update_zip" \
    --repo "$repo" --title "iPhoneMirror $version" --notes "$release_notes"

# --- Append the appcast entry and re-sign the feed ---
enclosure_url="https://github.com/$repo/releases/download/v$version/iPhoneMirror-$version.zip"
pub_date="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"
python3 - "$version" "$next_build" "$pub_date" "$enclosure_url" "$ed_signature" "$enclosure_length" <<'PY'
import sys
import xml.etree.ElementTree as ET

version, build, pub_date, url, ed_signature, length = sys.argv[1:7]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
for prefix, uri in ns.items():
    ET.register_namespace(prefix, uri)

path = "docs/appcast.xml"
# ElementTree silently drops comments on a parse/write round-trip; keep the
# file's explanatory header comment by re-inserting it after writing.
with open(path, encoding="utf-8") as f:
    original = f.read()
comment_start = original.find("<!--")
comment_end = original.find("-->") + len("-->") if comment_start != -1 else -1
comment_block = original[comment_start:comment_end] if comment_start != -1 else None

tree = ET.parse(path)
channel = tree.getroot().find("channel")

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, "{%s}version" % ns["sparkle"]).text = build
ET.SubElement(item, "{%s}shortVersionString" % ns["sparkle"]).text = version
ET.SubElement(item, "{%s}minimumSystemVersion" % ns["sparkle"]).text = "27.0"
ET.SubElement(item, "enclosure", {
    "url": url,
    "sparkle:edSignature": ed_signature,
    "length": length,
    "type": "application/octet-stream",
})

# Newest first.
first_item = channel.find("item")
if first_item is not None:
    channel.insert(list(channel).index(first_item), item)
else:
    channel.append(item)

ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)

if comment_block:
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    lines.insert(1, comment_block + "\n")
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
PY
"$sign_update" --account "$sparkle_account" docs/appcast.xml

# --- Commit and push the version bump + appcast ---
git add Resources/Info.plist docs/appcast.xml
git commit -m "Release iPhoneMirror $version"
git push

echo "Released iPhoneMirror $version: https://github.com/$repo/releases/tag/v$version"
echo "Appcast updated — make sure GitHub Pages is serving docs/appcast.xml before relying on it."
