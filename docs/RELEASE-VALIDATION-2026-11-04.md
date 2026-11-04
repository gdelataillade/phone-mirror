# Release validation — 4 November 2026

Starting integration commit: `1f4ea9219e9770fd2380641f66a43033b4fe2f87`, based on
remote main `381d466f2a415afade16759e593a34791d430ce8`.
All work is in the isolated `fix/audit-hardening-main-20261104` worktree.
No live push, tag, GitHub release, feed publication or notarization submission is
authorized or performed by this validation task.

## Synthetic TLS peers

Backend/tests/tls.rs compiles the exact private production verifier/configuration
source via a path module, without exposing it as a new application API. Each
fixture generates new synthetic certificate/key material in memory with rcgen;
no device pairing record, stored private key or external TLS peer is used.

For both TLS 1.2 and TLS 1.3:

- A pinned peer completes a full in-memory client/server handshake, with a DNS
  name deliberately different from the certificate's name.
- A valid but unpaired certificate fails with the pairing-certificate error.
- A pinned peer whose signer corrupts the handshake signature fails with
  InvalidCertificate(BadSignature).

These are protocol-level tests with positive controls, not mocks of the decision
being tested. The three test cases exercise six handshake paths. They are now
included in scripts/test.sh. New certificate-generation dependencies are dev-only.

## Publication ordering

scripts/release.sh still prepares and notarizes/signs artifacts when explicitly
invoked for a release. It now delegates publication to scripts/publish-release.sh.
Both paths require a reviewed main branch. Publication is ordered as follows:

1. Validate the built source SHA, clean index/change scope, increasing version and
   build, artifact names, and matching prepared appcast enclosure/length/signature.
2. Commit/push only Info.plist; the published feed still advertises the old version.
3. Create a draft release pinned to that source/version commit and upload assets.
4. Download the draft assets and compare their bytes to the prepared files.
5. Publish the release, then verify both unauthenticated public download URLs and
   byte equality with bounded curl requests.
6. Recheck source HEAD and the prepared feed's hash; only then commit/push the feed.

The version tag stays on the source/version commit. Failure before the final feed
push does not advertise missing assets. Partial success can leave a version commit,
a draft, or a public release behind. If only the final push fails, the feed commit
remains local and can be reviewed/retried with git push; the script does not force
push, overwrite an existing release or automatically rebuild/re-sign artifacts.

Sixteen offline tests use real temporary local Git repositories and fake
GitHub/download/push commands. They cover ordering, upload/draft/public byte
mismatch, unavailable public URLs, publish/source-push/feed-push failures, existing
releases, mismatched enclosure metadata, feature branches, built-source drift and
concurrent HEAD/feed edits, existing tags and failed remote tag queries. No test contacts GitHub or publishes anything.

Python bridge/publication tests are now included in the default scripts/test.sh
runner, with bytecode caches disabled.

## Candidate/device results

Pending the full automated run, candidate rebuild and coordinated device checks.
The old audit/device evidence is not substituted for matching-build acceptance.

Automated checks completed: **186 passed** (68 Rust, 84 Swift, 34 Python).
The candidate release build and strict ad-hoc signature verification passed.
Executable SHA-256:
`38c31d2c1a8a9c56d34f453edab99d565da000882597102fc08188275f4012cc`.
This matches the integration binary because the additional changes are test and
publication tooling. Version metadata remains 0.5.2/build 8; a public patch release
would be 0.5.3/build 9 after approval and the final signed/notarized build.

Read-only signing preflight found one Developer ID identity and successfully read
the existing iPhoneMirror-notary profile's history. No signing credential contents
were printed, and no production notarization submission or release was performed.

Proposed 0.5.3 release notes:

- Strengthens paired-device TLS verification and encrypts Apple setup requests.
- Bounds malformed HTTP responses and updates affected transport dependencies.
- Improves audio mute/resume, startup recovery and buffering behavior.
- Allows more time for device preparation before waiting for the first picture.
- Rejects stale automation app responses after cancellation or reconnection.

No Wi-Fi connection fix is claimed: the earlier discovery failure involved the
phone and Mac being on different networks. Main's existing camera expiry,
automation observations/events and saved agent-access preference are preserved.

### Readiness at the current handoff

| Check | Result |
| --- | --- |
| Paired/unpaired/corrupted-signature TLS peers, TLS 1.2 and 1.3 | Passed |
| Full native/Swift/Python automated coverage | 186 passed |
| Release publication ordering and failure paths | 16 offline cases passed |
| Build, ad-hoc signature, formatting/diff/secret scan | Passed |
| Existing Developer ID identity / notary profile read | Available |
| Candidate USB/Wi-Fi / audio / observation and cancellation | Pending coordinated device QA |
| Candidate Camera baseline and post-disconnect release | Pending user baseline response |
| Candidate sleep/wake and longer stability | Pending |
| Public release, notarized production distribution, feed publication | Not performed |

**Decision: hold public release until matching-build device acceptance is recorded.**
The candidate was opened from this worktree and its observation/events API was
verified while disconnected. The user reported the phone connected/ready; the
older audit app was stopped and quit. A baseline Camera check was requested before
starting the candidate's first stream. No candidate device stream or phone input
has been performed while that response is pending.
