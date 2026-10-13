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
USB device QA resumed with the user's connected, unlocked iPhone on 2026-10-13.
The results below supplement the automated evidence.

## Automated results (2026-10-13)

- Final pre-PR run: all 78 Swift tests and all 56 Rust tests across
  library/media/opack passed, including queue-overflow, dispatch-handle lifetime,
  and encoded event-query regressions.
- MCP: all 18 bridge/HTTP tests passed on the final bridge source.
- Rust formatting, strict Swift formatting for changed files, and Git whitespace
  checks passed.
- `scripts/build.sh` produced an ad-hoc signed local app; `codesign --verify
  --deep --strict build/iPhoneMirror.app` passed. Existing macOS 27 recording API
  deprecation warnings remain.
- After device QA exposed escaped-cursor query rejection, 28 focused Swift tests
  (including the new HTTP parser regression) and all 18 Python tests passed.
  The rebuilt app passed strict signature verification.
- No installation, release publication, or MCP registration changes were made.

## Physical-device results (2026-10-13)

Tested the locally built app over USB with an unlocked iPhone 17 on iOS 27.
Calls used this worktree's actual stdio MCP bridge, including initialization,
tool routing, HTTP transport, and MCP image responses. The globally registered
MCP tool schema was unchanged. Screenshots and raw receipts stayed in a private
temporary directory and are not committed.

| Check | Observed result |
| --- | --- |
| Tap, swipe, text, backspace, Home with observation | Dispatch receipts and separate image blocks returned; fresh frame receipt times exceeded monotonic dispatch confirmation. Settings navigation, scrolling, query entry/deletion and eventual Home were visually checked. |
| Freshness versus UI completion | The first image sometimes showed an animation or paste permission; a later screenshot established the resulting UI. Fresh does not mean settled or successful. |
| Idle observation timeout | A 0.1-second observation budget returned `dispatched` plus `timed_out`, without an image, in about 0.19 seconds including input dispatch. A 5-second budget also timed out correctly. No bridge retry occurred. |
| Stop Agent Action | The visible menu interrupted a pending post-dispatch observation: `cancelled`, `timedOut: false`, no image. Status then reported `busy: false`; a subsequent Home action worked. |
| Event history and reconnect | Ordered manualReconnect, closed, opening, transportChanged (USB), and firstFrame events included session IDs and precise host timestamps. One opening-to-firstFrame interval was 0.414 seconds. |
| Event wait | A 0.1-second wait timed out in 0.112 seconds; an active 5-second wait returned firstFrame on reconnect after 4.035 seconds, before its deadline. |
| Old session guard | A tap using the pre-reconnect session returned HTTP 409 before dispatch. |
| App restart | Reading with the previous app generation's cursor returned `gap: true` and the new history. |
| Access revocation | Disabling access ended a pending event wait with a transport error after 1.353 seconds. The window remained responsive. |
| Lock semantics | Status and event responses consistently reported `lockState: unknown`. |

Device QA found and fixed a real integration bug: the HTTP parser rejected the
bridge's percent-encoded event cursor and fractional timeout. Event routes now
decode a restricted value alphabet; malformed escapes, control characters,
duplicate names, and encoded names remain rejected. Other routes retain their
existing strict query rules. The regression covers the real encoded cursor.

Cleanup: cleared the disposable Settings search, restored Home, disabled agent
access, disconnected, and quit the test app. Phone settings and audio volume
were not changed. The text test used the existing clipboard-based typing path,
so the iPhone clipboard may still contain `Wi-Fi`.

Not exercised physically: cable removal/Wi-Fi fallback, screen rotation,
cancellation during the gesture itself, disconnect during an observation,
native dispatch failure, and bounded-history eviction. Automated coverage is
not a substitute for those hardware checks. No camera app or glasses-camera
pipeline was tested; no lock/unlock detection is implemented.

## Device reproduction and remaining checks

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
