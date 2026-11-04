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

The rebuilt candidate completed the coordinated checks below. The old audit/device
evidence is not substituted for matching-build acceptance.

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
| Candidate USB video, Home/Settings, fresh observations and events | Passed |
| Candidate mutation/gesture exclusion in both directions | Passed; competing requests rejected with HTTP 409 |
| Candidate app cancellation and interrupted-action receipts | Passed; busy state cleared |
| Candidate audio mute/resume and volume | User confirmed all checks passed |
| Candidate audio after USB reconnect | User confirmed automatic recovery |
| Candidate Wi-Fi handoff, Home/Settings input and manual reconnect | Passed; actual Wi-Fi transport confirmed |
| Candidate Camera baseline | User confirmed normal live preview before streaming |
| Candidate post-disconnect Camera release | User confirmed normal live preview after explicit Disconnect and 20-second wait |
| Candidate sleep/wake | Skipped at user request; unverified |
| Candidate longer Wi-Fi stability | Concern: repeated recovered stalls; investigate before release |
| Public release, notarized production distribution, feed publication | Not performed |

**Decision: hold public release pending review of the longer Wi-Fi run
stalls.** Sleep/wake was skipped at the user's request. Short device checks passed,
but they do not establish stable long-running Wi-Fi streaming.
The candidate was opened from this worktree after the older audit app was stopped
and quit, and after the user confirmed a normal Camera preview. USB video, Home and
Settings navigation were verified. Both input actions reported dispatched/fresh
observations and the resulting screens were inspected. Events reported opening,
USB transport and the first frame without a cursor gap.

Concurrent device checks rejected an app mutation during a gesture and a gesture
during an app mutation (HTTP 409). Cancelling an in-flight app request rejected its
stale response. Cancelling an observed two-second gesture returned accepted with
`dispatchStatus: unknown` and `observationStatus: action_interrupted`; this does not
claim the gesture was never dispatched. Busy state cleared after all four cases.
A subsequent USB diagnostics sample showed 12,456 assembled/queued frames, zero
encoded queue overflows, discontinuities, media feedback failures and decoder
errors, and zero failures across 1,153 orientation queries. This is a sampled
session observation, not a measured end-to-end latency or frame-rate benchmark.

After the user confirmed music was playing, mute was exercised for five seconds,
then resumed, volume lowered to 25% and restored to 50%. A manual reconnect
returned the app to enabled live controls. The user confirmed prompt mute, resume
without stale replay, the expected 25%/50% volume changes, and automatic Mac audio
recovery after USB reconnect. Wi-Fi audio and output-device switching were not
separately confirmed. Agent access was switched off after automation QA; the discovery file was absent and its former
loopback port was no longer listening.

After the user unplugged USB, the app selected Wi-Fi and displayed live video.
Home and a tap opening Settings were verified against the resulting mirrored
screens. A manual reconnect while USB remained unplugged returned to live Wi-Fi
with enabled controls. A diagnostics sample showed 947 assembled/queued frames,
zero decoder errors, queue overflows, discontinuities or media feedback failures,
and zero failures across 54 orientation queries. The preceding USB session lasted
about 25 minutes after its manual reconnect, recording 40,402 frames with zero
errors in those counters. USB removal ended that transport with remote release
unconfirmed because the device was unreachable, then Wi-Fi produced its first
picture about two seconds later. Manual close diagnostics reported waiting for
the iPhone's 20-second stream expiry; this is not proof that Camera was released.

### Final Camera check and stability caveat

Mirroring was explicitly disconnected over Wi-Fi, audio restored to muted at 50%,
and the app verified idle with phone controls disabled. After a 20-second wait,
the user opened Camera directly on the iPhone and confirmed a normal live preview.
The native cleanup status still described pending stream expiry; physical Camera
availability is established by the user's check, not that status alone.

The final diagnostics showed 25 total connection attempts during the candidate
run. The retained 60-event tail contains **10 decoded-video stalls and one native
connection failure** during the longer Wi-Fi period, with automatic reconnects and
new first pictures afterward. Many stalled sessions recorded one encoded queue
overflow/keyframe request despite zero decoder errors; the native failure recorded
one orientation timeout at 750 ms. These observations do not establish the root
cause or that the audit introduced a regression. Earlier zero-error samples must
not be generalized to the full Wi-Fi run. The final session ran about 26 minutes
before the explicit stop and recorded 23,860 frames with no queue overflow or
decoder error. Intermittent earlier recovery still warrants investigation.

The sanitized report is saved locally (ignored build evidence) at
`work/integration-validation/candidate-final-diagnostics.txt`. No screen content,
device identifier, token or raw error is included. A follow-up should compare a
controlled Wi-Fi run against current main under the same network/device conditions,
then investigate queue-overflow and orientation-timeout recovery as supported by
that comparison. Sleep/wake remains outside this completed QA pass by user choice.
No push, tag, public release, feed publication or production notarization occurred.

Final cleanup verified the candidate process exited, `audioMuted=1`,
`audioVolume=0.5`, and `automationAccessRequested=0`. The automation discovery file
was absent and its former loopback port was closed. The original checkout and its
three unrelated feasibility documents were preserved.
