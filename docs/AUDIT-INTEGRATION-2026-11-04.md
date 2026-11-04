# Audit integration onto current main — 4 November 2026

Base: `381d466f2a415afade16759e593a34791d430ce8` (remote main, after v0.5.2).
Audit source: `22dbca4fdb306fbc236c61bb09c85a92e5424de7`.
Branch: `fix/audit-hardening-main-20261104`, in a separate worktree.

## Scope decisions

| Area | Integration |
| --- | --- |
| Device TLS | Pin the pairing certificate; verify TLS handshake signatures; propagate client-key configuration errors. |
| TSS/HTTP | Use HTTPS, restrict HTTPS redirects, cap response allocation, reject oversized lengths and conflicting/truncated framing. |
| Dependencies | Keep the audit's four backend lockfile patch updates. |
| Audio | Apply settings on the audio loop, retry failed startup, request configuration recovery, cap scheduled PCM at 200 ms. |
| Watchdog | Separate the preparation bound from the first-picture deadline. |
| Transport report | Already fixed on main with an allowlisted string. Preserve that API and its regression tests; port only transport-neutral stage/feedback wording. |
| Automation concurrency | Main already excludes screen-changing app requests and gestures in both directions. Preserve its existing read-only list concurrency and 429 app-request limit. |
| App response lifetime | Port cancellation checks and post-await validation of agent access, session, input epoch and control availability. Flush held input before a screen-changing app request. |

The audit branch's replacement of all app/gesture gates with one busy flag was
not applied: newer main already fixes the mutation race while allowing read-only
app listing. App requests still retain their existing native timeout and cannot
undo an already delivered launch/termination. An input-epoch change causes the
pending response to be rejected, including when the native operation itself
already completed.

## Preserved main behavior

No changes were made to the current backend's dispatch marker, owned-stream
expiry/keepalives, release-status handling, C header, automation event protocol,
observation gate, stored agent-access preference, or release metadata/feed.
NativeSession retains `pm_close_with_health` and `InputDispatch`; its audio
ownership edits were applied around those newer additions.

`Resources/Info.plist` remains v0.5.2. This integration does not publish a release,
bump a version, push a branch, create a remote PR, or modify the appcast. The
original checkout remains at 22dbca4 and its three unrelated feasibility documents
are excluded and unchanged.

## Validation

Integration checks and results are recorded below after the combined build/test
run. Logs and the local app bundle are generated in this worktree's ignored
`work/integration-validation/` and `build/` directories.

The device acceptance entries in VALIDATION.md describe the original audit
branch and their recorded binary hashes. They do not establish device acceptance
of this combined main-based build. Before distribution, perform matching-build
USB/Wi-Fi mirroring, audio, automation observation/cancellation, camera release
and sleep/wake checks. Synthetic negative TLS peer fixtures, fresh TSS
personalization and extended stability remain unverified by this integration.

### Completed checks

- `scripts/build.sh`: release Rust/Swift build and local ad-hoc signing passed.
- `codesign --verify --deep --strict`: passed.
- `scripts/test.sh`: 65 Rust and 84 Swift tests passed, including upstream media
  expiry/keepalive/dispatch and automation observation regressions plus the ported
  HTTP, playback-budget and watchdog checks.
- Python MCP bridge tests: 18 passed. **167 automated tests in total.**
- Rust formatting and conflict-marker/diff checks passed.
- Sixteen critical upstream files were checked byte-for-byte against the base,
  including the camera cleanup/keepalive/dispatch backend, automation protocol,
  event/observation tests, saved-preference model/app entry point, C header,
  release script, Info.plist and appcast. All were unchanged.
- The original checkout's HEAD, tracked-file status and three feasibility-document
  hashes were checked and remained unchanged.

Built executable SHA-256:
`38c31d2c1a8a9c56d34f453edab99d565da000882597102fc08188275f4012cc`.
The app remains version 0.5.2/build 8 and was not launched, installed or distributed
as part of this integration. The original app/device session was not taken over.

Reproduce automated checks from this worktree with `scripts/build.sh`, then
`scripts/test.sh`, and `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests`.
