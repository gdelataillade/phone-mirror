# Action observation and connection events: validation

## Scope and evidence

This change adds opt-in action observation and connection event history to the
existing local HTTP API and Python MCP bridge. It does not add screen-lock
detection, log capture, leases, or accessibility inspection. Frame freshness
measures the mirror stream only, not an app's glasses-camera pipeline.

Automated checks cover native marker ordering/failure/lifetime, guarded frame
freshness, event precision/retention/cursor restart semantics, strict option
validation, MCP routing, image content, and timeout responses without retries.
These checks do not establish real-device dispatch timing or UI success.
Device QA remains pending while physical-device testing is on hold.

## Automated results (2026-10-13)

- Swift: 77 tests passed in the full suite; 30 automation/diagnostics tests passed
  again after the final response and retention changes.
- Rust: 54 tests passed across library/media/opack; all 4 dispatch tests passed
  after adding the queue-overflow and handle-lifetime regressions (2 additional
  cases beyond that full run).
- MCP: all 18 bridge/HTTP tests passed on the final bridge source.
- Rust formatting, strict Swift formatting for changed files, and Git whitespace
  checks passed.
- `scripts/build.sh` produced an ad-hoc signed local app; `codesign --verify
  --deep --strict build/iPhoneMirror.app` passed. Existing macOS 27 recording API
  deprecation warnings remain.
- No physical-device tests, installation, release publication, or MCP registration
  changes were performed.

## Reproduce on a device when testing resumes

1. Build this branch with `scripts/build.sh`. Stop any existing mirror session
   before opening this build. Enable **Automation → Enable Agent Access** and
   start a fresh MCP connection using this checkout's `scripts/iphonemirror_mcp.py`.
   Confirm `iphone_status` advertises `observe_after`, `events`, and `eventTypes`.
2. Open Settings. Take a screenshot, then tap a harmless navigation item with
   its `sessionID`/`observationID` and `observeAfter: true`. Confirm one tool call
   returns an action ID, dispatch status, timestamps, and an MCP image. Visually
   verify navigation. For `fresh`, check frame monotonic receipt time is greater
   than dispatch confirmation time. Repeat with a swipe, search text, and key.
   Clear the disposable search text afterward.
3. On an idle screen, tap a noninteractive area with a short observation timeout.
   Either a genuinely newer frame or an explicit `timed_out` is valid. The action
   must not be replayed automatically. Verify the reported dispatch result is
   retained even without an image.
4. While an action or observation wait is active, use **Stop Agent Action** or
   Command–Escape. Confirm input is released and the action cannot return a
   successful fresh observation after cancellation. Repeat with a reconnect:
   the old session must never produce an image labelled as the new session.
5. Capture `eventCursor` from status. Disconnect/reconnect the USB cable (or use
   Reconnect Now). Read events after that cursor, and verify ordered connection
   transitions with changing session IDs and precise host timestamps. If Wi-Fi
   fallback is configured, confirm the reported transport matches it. Check
   `lockState` stays `unknown`; do not interpret an absence of video as lock.
6. Wait for `firstFrame` after a current cursor while leaving the connection
   unchanged: it should time out in about the requested interval and retain a
   usable `nextCursor`. Restart the Mac app, re-enable access, and read using the
   previous app's cursor: `gap` must be true. Event waits must leave the Mac UI
   responsive; access revocation must end pending requests.
7. Disable agent access and close the test build when done. Restore the usual
   MCP registration if it was temporarily pointed to this worktree.

Screen rotation is an additional check in an app that supports it: request
rotation with observation enabled, verify orientation and coordinates in the
returned image, then restore the original orientation. A rotation request may
be dispatched without iOS accepting it; inspect the picture rather than treating
the dispatch result as a rotation assertion.
