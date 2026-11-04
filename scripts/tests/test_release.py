"""Offline publication orchestration: real local Git, fake GitHub/push/downloads."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

PUBLISH = Path(__file__).resolve().parents[1] / "publish-release.sh"
REAL_GIT = shutil.which("git")
# Every network-capable command is intercepted. Unknown fake commands fail closed.
FAKE = r'''
import json, os, pathlib, shutil, subprocess, sys
root = pathlib.Path(os.environ['PM_RELEASE_TEST_ROOT'])
state_path = root / 'state.json'
state = json.loads(state_path.read_text())
a = sys.argv[1:]
mode = os.environ.get('PM_RELEASE_TEST_FAILURE', '')
tool = pathlib.Path(sys.argv[0]).name
log = root / 'events.jsonl'
def event(kind, **extra):
    with log.open('a') as out: out.write(json.dumps({'kind':kind, **extra})+'\n')
def save(): state_path.write_text(json.dumps(state))
def asset(name): return root / 'repo' / 'build' / name
if tool == 'git':
    if a and a[0] == 'ls-remote':
        sys.exit(0 if mode == 'existing_tag' else 128 if mode == 'tag_lookup_failed' else 2)
    if a and a[0] == 'push':
        feed = subprocess.check_output([os.environ['PM_RELEASE_REAL_GIT'], 'show', 'HEAD:docs/appcast.xml'], text=True)
        new_feed = '0.5.3' in feed
        event('push', newFeed=new_feed)
        if mode == ('feed_push' if new_feed else 'source_push'): sys.exit(1)
        state['remoteFeedNew'] = new_feed; save(); sys.exit(0)
    os.execv(os.environ['PM_RELEASE_REAL_GIT'], [os.environ['PM_RELEASE_REAL_GIT'], *a])
if tool == 'gh':
    op = a[:2]
    if op == ['release','view']:
        sys.exit(0 if state.get('created') else 1)
    if op == ['release','create']:
        event('draft')
        assert '--draft' in a
        assert '--target' in a
        if mode == 'upload': sys.exit(1)
        state['created'] = True; save(); sys.exit(0)
    if op == ['release','download']:
        assert state.get('created') and not state.get('published')
        name = a[a.index('--pattern')+1]
        event('draft_download', name=name)
        dest = pathlib.Path(a[a.index('--dir')+1]) / name
        dest.write_bytes(b'corrupt' if mode == 'draft_bytes' else asset(name).read_bytes())
        sys.exit(0)
    if op == ['release','edit']:
        event('publish')
        if mode == 'publish': sys.exit(1)
        assert state.get('created') and '--draft=false' in a
        state['published'] = True; save(); sys.exit(0)
    raise SystemExit('Unexpected fake gh call')
if tool == 'curl':
    assert state.get('published')
    url = next(x for x in a if x.startswith('https://'))
    name = url.rsplit('/',1)[1]
    event('public_download', name=name)
    if mode == 'public_http': sys.exit(22)
    dest = pathlib.Path(a[a.index('--output')+1])
    dest.write_bytes(b'corrupt' if mode == 'public_bytes' else asset(name).read_bytes())
    if mode == 'feed_changed': pathlib.Path('docs/appcast.xml').write_text('changed during publication')
    if mode == 'head_changed' and not state.get('headChanged'):
        pathlib.Path('concurrent.txt').write_text('concurrent source edit')
        subprocess.run([os.environ['PM_RELEASE_REAL_GIT'],'add','concurrent.txt'],check=True)
        subprocess.run([os.environ['PM_RELEASE_REAL_GIT'],'commit','-m','concurrent edit'],check=True,stdout=subprocess.DEVNULL)
        state['headChanged'] = True; save()
    sys.exit(0)
raise SystemExit('Unexpected fake tool')
'''


def feed(version, build, size=3):
    return f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:shortVersionString>{version}</sparkle:shortVersionString><sparkle:version>{build}</sparkle:version>
<enclosure url="https://github.com/gdelataillade/phone-mirror/releases/download/v{version}/iPhoneMirror-{version}.zip"
length="{size}" sparkle:edSignature="synthetic-public-signature" /></item></channel></rss>'''


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        for name in ["scripts", "Resources", "docs", "build"]:
            (self.repo / name).mkdir(parents=True, exist_ok=True)
        self.bin.mkdir()
        shutil.copy2(PUBLISH, self.repo / "scripts/publish-release.sh")
        (self.repo / ".gitignore").write_text("build/\n")
        self.info = self.repo / "Resources/Info.plist"
        self.appcast = self.repo / "docs/appcast.xml"
        self.info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.5.2", "CFBundleVersion": "8"}))
        self.appcast.write_text(feed("0.5.2", 8))
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Synthetic Release Test")
        self.git("config", "user.email", "synthetic@example.invalid")
        self.git("add", ".")
        self.git("commit", "-m", "baseline")
        self.source_sha = self.git("rev-parse", "HEAD").strip()
        self.info.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.5.3", "CFBundleVersion": "9"}))
        self.appcast.write_text(feed("0.5.3", 9))
        self.dmg = self.repo / "build/iPhoneMirror-0.5.3.dmg"
        self.zip = self.repo / "build/iPhoneMirror-0.5.3.zip"
        self.dmg.write_bytes(b"dmg")
        self.zip.write_bytes(b"zip")
        self.state = self.root / "state.json"
        self.state.write_text("{}")
        for tool in ["git", "gh", "curl"]:
            p = self.bin / tool
            p.write_text(f"#!{sys.executable}\n" + FAKE)
            p.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output([REAL_GIT, *args], cwd=self.repo, stderr=subprocess.DEVNULL, text=True)

    def run_publish(self, failure=""):
        env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ["PATH"],
                   PM_RELEASE_TEST_ROOT=str(self.root), PM_RELEASE_REAL_GIT=REAL_GIT,
                   PM_RELEASE_TEST_FAILURE=failure)
        return subprocess.run(["/bin/bash", "scripts/publish-release.sh", "0.5.3", str(self.dmg), str(self.zip), self.source_sha],
                              cwd=self.repo, env=env, capture_output=True, text=True, timeout=20)

    def events(self):
        p = self.root / "events.jsonl"
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def test_feed_is_pushed_only_after_verified_public_assets(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.events()
        self.assertEqual([v["kind"] for v in events],
                         ["push", "draft", "draft_download", "draft_download", "publish",
                          "public_download", "public_download", "push"])
        self.assertFalse(events[0]["newFeed"])
        self.assertTrue(events[-1]["newFeed"])
        self.assertTrue(json.loads(self.state.read_text())["remoteFeedNew"])
        self.assertEqual(self.git("show", "--format=", "--name-only", "HEAD").strip(), "docs/appcast.xml")
        self.assertEqual(self.git("show", "--format=", "--name-only", "HEAD^").strip(), "Resources/Info.plist")

    def test_upload_failure_never_publishes_or_advertises(self):
        self.assert_no_feed_after_failure("upload", public=False)

    def test_wrong_draft_bytes_never_publish_or_advertise(self):
        self.assert_no_feed_after_failure("draft_bytes", public=False)

    def test_publish_failure_never_advertises(self):
        self.assert_no_feed_after_failure("publish", public=False)

    def test_wrong_public_bytes_never_advertise(self):
        self.assert_no_feed_after_failure("public_bytes", public=True)

    def test_unavailable_public_url_never_advertises(self):
        self.assert_no_feed_after_failure("public_http", public=True)

    def test_source_push_failure_never_creates_release(self):
        self.assertNotEqual(self.run_publish("source_push").returncode, 0)
        self.assertEqual([v["kind"] for v in self.events()], ["push"])

    def test_feed_push_failure_keeps_remote_feed_old(self):
        self.assertNotEqual(self.run_publish("feed_push").returncode, 0)
        self.assertTrue(json.loads(self.state.read_text())["published"])
        self.assertFalse(json.loads(self.state.read_text())["remoteFeedNew"])

    def test_mismatched_enclosure_is_rejected_before_mutation(self):
        self.appcast.write_text(feed("0.5.3", 9, size=100))
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertEqual(self.git("log", "-1", "--format=%s").strip(), "baseline")

    def test_feed_edit_during_publication_is_not_advertised(self):
        self.assert_no_feed_after_failure("feed_changed", public=True)

    def test_concurrent_source_commit_is_not_advertised(self):
        self.assert_no_feed_after_failure("head_changed", public=True)

    def test_built_source_mismatch_is_rejected_before_mutation(self):
        self.source_sha = "0" * 40
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.events(), [])

    def test_existing_tag_is_not_reused_for_new_artifacts(self):
        self.assertNotEqual(self.run_publish("existing_tag").returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertEqual(self.git("log", "-1", "--format=%s").strip(), "baseline")

    def test_remote_tag_query_failure_stops_publication(self):
        self.assertNotEqual(self.run_publish("tag_lookup_failed").returncode, 0)
        self.assertEqual(self.events(), [])

    def test_existing_release_is_not_overwritten(self):
        self.state.write_text('{"created":true}')
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.events(), [])

    def test_feature_branch_is_rejected_before_network_calls(self):
        self.git("checkout", "-b", "feature")
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.events(), [])

    def assert_no_feed_after_failure(self, mode, public):
        result = self.run_publish(mode)
        self.assertNotEqual(result.returncode, 0)
        state = json.loads(self.state.read_text())
        self.assertEqual(bool(state.get("published")), public)
        self.assertFalse(state.get("remoteFeedNew"))
        self.assertNotIn("0.5.3", self.git("show", "HEAD:docs/appcast.xml"))
