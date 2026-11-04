# Release validation — 4 November 2026

**Status: not ready for release.** The affected device runs overlapped a second
installed mirror client. They are not isolated acceptance evidence or proof of a
candidate regression. A clean single-client baseline and matching-build acceptance
remain required. This record covers the local trim and review commit. No new
device QA, push, release, feed update or production notarization was performed.

## Scope and preservation

Worktree: `fix/audit-hardening-main-20261104`, review parent `3feee73`, containing
integration `1f4ea92` and TLS/publication validation `c0c07e7`, based on main `381d466`.
The committed TLS, HTTP, audio, preparation, automation and release-publication
changes are unchanged by this trim. Version metadata remains 0.5.2/build 8.

Before trimming, all 12 modified/untracked source/document files were copied and
SHA-256 verified in `work/integration-validation/trim-snapshot-20261104-180005/`.
That ignored local snapshot contains `manifest.json`, tracked/index patches,
status, exact file copies and the full 621-line prior QA chronology at
`files/docs/RELEASE-VALIDATION-2026-11-04.md`. Existing diagnostic reports and logs
remain in `work/integration-validation/`. The original checkout and its unrelated
feasibility documents are preserved. The snapshot and diagnostic artifacts remain
ignored and are excluded from the review commit.

## Retained changes

- Recovery bookkeeping is independent of lifetime error totals. Native damage
  remains pending until a fresh sync picture is successfully queued. The Mac
  requires decoded progress through that checkpoint and a drained queue before
  allowing responsive static-screen idle. Decoded queue positions include earlier
  failed/skipped events, so historical drops cannot permanently poison idle.
- New damage, queued-but-undecoded sync pictures, stalled decoding and cached
  orientation heartbeats cannot hide missing decoded progress. The existing
  one-second Swift stalled-output deadline remains; native refresh/restart and
  startup/preparation deadlines are unchanged.
- Saved diagnostics retain an allowlisted native failure category across stale
  snapshots, cleanup and reconnect. Categories distinguish input timeout/error,
  transport, feedback, orientation, recovery, setup and worker exits without raw
  error text, command payloads or device identity. Unknown codes get a generic
  label; a missing category remains decodable. Existing recovery policy is unchanged.

Independent offline comparison reproduced the historical-loss idle rejection in
the pre-change source and its correction in the retained change; both versions
still expired a cached heartbeat. This demonstrates the bookkeeping behavior, not the cause of
any confounded device stall. Orientation liveness alone does not establish that
video content is current; no new freshness policy is added here.

## Deferred changes

Removed from this candidate, preserved in the snapshot:

- The 100 ms admission retry, polling/pressure state, extra held frame, admission
  wait counter and their dependent tests/documentation.
- Incremental vendor assembler draining and its two tests. The vendor assembler
  and its README are byte-identical to HEAD, preserving the original provenance.
- The extra eight-second Swift recovery grace. Its test now checks that pending
  recovery or an undecoded sync cannot extend the one-second output deadline.

These were not established as necessary or correctly tuned by isolated device
runs. The event queue again holds 16 items with the committed immediate-full
recovery path; RTCP packet builders, ports and field semantics are unchanged.

## Automated/build validation

**197 tests passed**: 72 Rust, 91 Swift and 34 Python. The eight deferred
admission/assembler tests are preserved in the snapshot rather than counted here.
The revised watchdog regression confirms unresolved recovery and an undecoded
sync cannot extend the existing one-second deadline. Formatting, diff checks,
release build and strict ad-hoc signature verification passed. Existing recording
API deprecation warnings remain unrelated to this change. No app was launched.

Executable SHA-256:
`fbdc4d6b46ad0a5fc5f2b61d34230a685f87c53bf111330f46e299a2982adc0e`.
Logs: `work/integration-validation/trim-build.log`, `trim-tests.log`,
`trim-focused-rust.log` and `trim-focused-swift.log`.

Committed validation still includes paired/unpaired/corrupt-signature TLS tests
for TLS 1.2/1.3 and 16 offline publication-order/failure tests. Those do not perform
GitHub writes or prove production distribution. No new device behavior is claimed
from automated checks or an ad-hoc signed build.

## Corrected device evidence

A separate `/Applications/iPhoneMirror.app` process (version 0.5.2) was found
actively mirroring over Wi-Fi after the candidate had quit. It had been running
for about 3 hours 40 minutes when checked; its saved report reached 71 attempts.
Earlier cleanup checked only the candidate process path and missed that client.
The affected control, audio, stability, long-silence and Camera observations are
confounded.
Synthetic tests and saved numeric observations remain valid within their scope.

The installed copy was disconnected and quit. A check across all app paths then
found no mirror app/probe process. After 30 seconds and closing/reopening Camera,
the user confirmed its preview worked. This does not retroactively validate
candidate-only teardown or establish that overlap caused every observed issue.
The installed app was not replaced or uninstalled; idle MCP bridge clients were
not killed or reconfigured. At that cleanup checkpoint, Agent Access was off,
with no discovery file or listener, and audio was muted at 50%.

The subsequent local review found the installed app running again, its Agent
Access preference enabled and its discovery file present. Process presence alone
does not establish mirroring or a working listener; neither was tested. This
review left the app and settings untouched and performed no new hardware QA.
Audio preferences still showed muted at 50%.

Retained artifacts include `installed-copy-concurrent-stream.txt`,
`failure-categories-final-reconnect.txt`, `failure-categories-wifi-idle.txt`,
`admission-wifi-early-failure.txt` and `recovery-fix-wifi-failure.txt` in the ignored
validation directory. Their device claims must be read with the qualification above.

## Future manual acceptance — not run by this task

1. Globally verify all mirror app/probe processes are closed. Confirm normal Camera
   preview; close Camera and leave the unlocked iPhone on Settings on the Mac's Wi-Fi.
2. Run exactly one verified executable/path/hash at a time. Check USB, Wi-Fi handoff,
   input, audio and reconnect, then changing/static screens for 20–30 minutes if
   the short check passes. Save diagnostics at the first failure. Stop and check
   Camera between builds; do not overlap installed, candidate or Xcode clients.
3. Explicitly Disconnect and quit, recheck all app paths, wait 30 seconds, then
   check physical Camera preview. Record whether Camera needed closing/reopening.
   Sleep/wake remains skipped at the user's request.
