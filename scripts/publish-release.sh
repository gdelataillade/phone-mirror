#!/bin/bash
# Publish prepared, signed artifacts before advertising them through Sparkle.
# Called by release.sh after notarization/signing. Does not build or sign anything.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-}"
dmg="${2:-}"
update_zip="${3:-}"
expected_source_sha="${4:-}"
repo="gdelataillade/phone-mirror"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ ! -f "$dmg" ] || [ ! -f "$update_zip" ]; then
    echo "Usage: scripts/publish-release.sh <major.minor.patch> <signed.dmg> <signed.zip> <built-source-sha>" >&2
    exit 1
fi
if [ "$(git branch --show-current)" != main ]; then
    echo "Release only reviewed changes from main." >&2
    exit 1
fi
if [ -z "$expected_source_sha" ] || [ "$(git rev-parse HEAD)" != "$expected_source_sha" ]; then
    echo "Source HEAD changed after preparation; rebuild before publishing." >&2
    exit 1
fi
if ! git diff --cached --quiet; then
    echo "The index must be empty before publishing prepared artifacts." >&2
    exit 1
fi
# Preparation may change only these two tracked files.
while IFS= read -r path; do
    case "$path" in
        Resources/Info.plist|docs/appcast.xml) ;;
        *) echo "Unexpected prepared change: $path" >&2; exit 1 ;;
    esac
done < <(git diff --name-only)
if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "Unexpected untracked files; review them before publishing." >&2
    exit 1
fi
if [ "$(basename "$dmg")" != "iPhoneMirror-$version.dmg" ] || [ "$(basename "$update_zip")" != "iPhoneMirror-$version.zip" ]; then
    echo "Artifact filenames must match the requested version." >&2
    exit 1
fi
tag="v$version"
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag already exists. Do not attach new artifacts to a different source commit." >&2
    exit 1
else
    tag_status=$?
    if [ "$tag_status" -ne 2 ]; then
        echo "Could not verify remote tag availability; publication stopped." >&2
        exit 1
    fi
fi
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "Release $tag already exists. Review it before resuming publication." >&2
    exit 1
fi
# Check that the staged feed advertises exactly the artifact/version being released.
python3 - "$version" "$repo" "$update_zip" <<'PY'
import os, plistlib, subprocess, sys, xml.etree.ElementTree as ET
version, repo, artifact = sys.argv[1:]
with open('Resources/Info.plist', 'rb') as source:
    info = plistlib.load(source)
previous = plistlib.loads(subprocess.check_output(['git', 'show', 'HEAD:Resources/Info.plist']))
if (tuple(map(int, version.split('.'))) <= tuple(map(int, previous['CFBundleShortVersionString'].split('.')))
    or int(info['CFBundleVersion']) <= int(previous['CFBundleVersion'])):
    raise SystemExit('Release version and build must both increase')
item = ET.parse('docs/appcast.xml').find('channel/item')
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
expected = f'https://github.com/{repo}/releases/download/v{version}/iPhoneMirror-{version}.zip'
if item is None:
    raise SystemExit('Prepared appcast has no release entry')
enclosure = item.find('enclosure')
if (info['CFBundleShortVersionString'] != version
    or item.findtext('sparkle:shortVersionString', namespaces=ns) != version
    or item.findtext('sparkle:version', namespaces=ns) != str(info['CFBundleVersion'])
    or enclosure is None or enclosure.get('url') != expected
    or enclosure.get('length') != str(os.path.getsize(artifact))
    or not enclosure.get('{'+ns['sparkle']+'}edSignature')):
    raise SystemExit('Prepared version, signed artifact and appcast do not match')
PY
prepared_feed_oid="$(git hash-object docs/appcast.xml)"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/iphonemirror-release.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
# Publish the source/version commit with the OLD feed. A failure from here onwards
# can leave a version commit or a release behind, but never a premature appcast.
git add -- Resources/Info.plist
git commit -m "Release iPhoneMirror $version" -- Resources/Info.plist
release_sha="$(git rev-parse HEAD)"
git push origin HEAD:refs/heads/main
release_notes="Release $version. See VALIDATION.md and the commit history for details."
gh release create "$tag" "$dmg" "$update_zip" --repo "$repo" \
    --target "$release_sha" --draft --title "iPhoneMirror $version" --notes "$release_notes"
# Verify uploaded draft bytes before making the release public.
for artifact in "$dmg" "$update_zip"; do
    name="$(basename "$artifact")"
    gh release download "$tag" --repo "$repo" --pattern "$name" --dir "$verification_dir"
    if ! cmp -s "$artifact" "$verification_dir/$name"; then
        echo "Uploaded draft asset does not match: $name. Feed was not published." >&2
        exit 1
    fi
done
gh release edit "$tag" --repo "$repo" --draft=false --latest
# Check unauthenticated public download URLs, not only GitHub's upload response.
for artifact in "$dmg" "$update_zip"; do
    name="$(basename "$artifact")"
    public_copy="$verification_dir/public-$name"
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 300 \
        "https://github.com/$repo/releases/download/$tag/$name" --output "$public_copy"
    if ! cmp -s "$artifact" "$public_copy"; then
        echo "Public asset does not match: $name. Feed was not published." >&2
        exit 1
    fi
done
if [ "$(git rev-parse HEAD)" != "$release_sha" ] || [ "$(git hash-object docs/appcast.xml)" != "$prepared_feed_oid" ]; then
    echo "Source or prepared feed changed during publication; feed was not published." >&2
    exit 1
fi
# Only now can Sparkle advertise the new enclosure. The tag stays on release_sha.
git add -- docs/appcast.xml
git commit -m "Publish Sparkle feed for iPhoneMirror $version" -- docs/appcast.xml
git push origin HEAD:refs/heads/main
echo "Released iPhoneMirror $version: https://github.com/$repo/releases/tag/$tag"
