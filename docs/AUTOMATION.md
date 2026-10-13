# Local automation API

iPhoneMirror exposes its existing USB session to local tools. Open the app,
connect an unlocked iPhone, then choose **Automation → Enable Agent Access**.
The window's subtitle shows when access is enabled and when an agent gesture is
running. Choosing **Enable Agent Access** again revokes access and cancels the
current gesture. Access starts off on every app launch. Nothing is sent to an AI provider by the app itself.

For Codex and other MCP clients, use the [stdio MCP bridge](MCP-BRIDGE.md).
An agent can observe a screenshot, tap/swipe/type, then observe again to test a
physical app. The app keeps sole ownership of the device connection; clients
must not start a second screen-stream connection.

## Discovery and authentication

While enabled, the app writes an owner-readable connection file:

`~/Library/Application Support/iPhoneMirror/automation.json`

Its JSON contains `url` (`http://127.0.0.1:<port>`) and `token`. By default the
port is assigned by the OS; **Automation → Port** can pin it to 8090 or a custom
port (1024–65535). A pinned port that is already taken turns access off with a
status message instead of silently moving. The token changes on every enable,
including when the port changes. Read this file per
request and send `Authorization: Bearer <token>`. Do not commit, print, share,
or put the token into an AI prompt. The bridge reads it without exposing it.
Disable/quit removes this instance's file. A crash can leave an unusable stale
file; enabling again replaces it.

With a pinned port, a plain shell script can read the token with `plutil`:

```sh
TOKEN=$(plutil -extract token raw ~/Library/Application\ Support/iPhoneMirror/automation.json)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8090/v1/status
```

The listener binds only to IPv4 loopback. Requests with an Origin header,
a Host other than `127.0.0.1:<port>` or `localhost:<port>`, missing token, oversized bodies, ambiguous length, transfer encoding
or HTTP pipelining are rejected. No CORS is provided. This protects against web
pages; it is not an isolation boundary against other processes running as your
Mac user. Clients authorized through this token can see the phone's current
screen and operate it while access is enabled.

## Endpoints

Responses are JSON (except `format=png` screenshots) with `Cache-Control: no-store`. HTTP/1.1, one request per
connection. POST requires `Content-Type: application/json` and Content-Length;
body limit 128 KiB. Errors have `{ "error": "..." }` and a non-200 HTTP status.

| Method/path | Result |
| --- | --- |
| `GET /v1/status` | Connection/control readiness, sessionID, observationID, dimensions, decoded FPS, busy flag, capabilities and `transport` (`usb`, `wifi` or null) |
| `GET /v1/screenshot` | Upright PNG as base64 `image`, mimeType, width/height, sessionID, observationID, frameID and ageSeconds |
| `GET /v1/screenshot?format=png` | The same PNG as the raw response body; metadata in `X-iPhoneMirror-Width`, `-Height`, `-SessionID`, `-ObservationID`, `-FrameID` and `-AgeSeconds` headers |
| `POST /v1/actions` | Validated input action; returns acceptance, actionID and sessionID; optional `observeAfter` waits for native dispatch and a newer decoded frame |
| `GET /v1/events` | Up to 256 timestamped connection events, cursor, gap and timeout status; optional `afterCursor`, `event`, `timeoutSeconds` |
| `GET /v1/apps` | Installed apps (App Store, Apple and developer builds): name, bundleID, version, build, running, developer and apple. `?scope=developer` lists only builds installed from Xcode or other developer tools |
| `POST /v1/apps/launch` | `{"bundleID": "…", "restart": false}` launches the app in the foreground and returns its `pid`; `restart: true` kills a running instance first |
| `POST /v1/apps/terminate` | `{"bundleID": "…"}` force-quits the app's running processes and returns their `pids`; 409 when it is not running |

Screenshots contain stream pixels only, without window chrome or bezel. They
are scaled to at most 1280 pixels on the long edge; add `scale=full` to keep the
stream resolution (for example 1206 × 2624), with either format. Unknown query
parameters are rejected, and other endpoints accept none.

```sh
curl -s -H "Authorization: Bearer $TOKEN" -o screen.png \
  "http://127.0.0.1:8090/v1/screenshot?format=png&scale=full"
```

 They are the latest decoded
frame, not a fresh camera capture or guaranteed post-action frame. An idle
iPhone can reuse its last frame; use frameID/ageSeconds and visual verification.
No screenshots or action text are saved to disk by the API.

## Apps

App requests use a separate device connection from touch and keyboard input, so
a slow answer never delays input. They take up to about 20 seconds; clients
should allow 30. One app request runs at a time (429 otherwise). Launch and
terminate accept an optional `sessionID` and return 409 while an agent gesture
is running; listing is allowed during a gesture. Bundle IDs are 1–255 letters,
digits, dots or hyphens. A launch or terminate refused by the iPhone (for
example an unknown bundle ID, or an Apple app iOS will not stop) returns 409 or
404 with the reason. There is no install or uninstall.

```sh
curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"bundleID":"com.apple.Preferences","restart":true}' \
  http://127.0.0.1:8090/v1/apps/launch
```

## Actions

Every body requires `op`. Unknown properties, boolean coordinates, invalid
numbers and out-of-range values are rejected. x/y use normalized coordinates
from 0 to 1 with top-left origin in the **returned upright screenshot**. The app
maps these through the current orientation to the native digitizer.

| op | Fields | Meaning |
| --- | --- | --- |
| `tap` | x, y, optional duration | Hold at a point then release; default 0.06 seconds, range 0.03–2 |
| `swipe` | x, y, toX, toY, optional duration | Linear drag, default 0.35 seconds, same range |
| `type` | text | Explicit paste into focused field; replaces the iPhone clipboard; max 65536 UTF-8 bytes, no NUL |
| `key` | key | enter, backspace, tab, escape, left, right, up, down, space |
| `home` | — | Home button |
| `button` | button: home, lock, volume_up or volume_down | Short hardware button press. **lock** turns the screen off and ends control until someone unlocks the phone by hand; there is no unlock action |
| `app_switcher` | — | App Switcher |
| `spotlight` | — | Spotlight gesture; use from Home |
| `control_center` | — | Control Center gesture |
| `rotate` | direction: left or right | Request rotation; phone/app rotation restrictions still apply |
| `release` | — | Cancel the current gesture and request release of held input |

Pass optional `sessionID` and `observationID` from the screenshot to reject
actions after reconnect or orientation/geometry changes. Switching between USB and
Wi-Fi (unplugging, or Reconnect Now with the cable back) is a reconnect: it starts a
new session, so observe again before acting. These guards do not
prove the same UI is still visible. Inspect after each action that can change
the screen. Screenshot encoding also rejects a session/orientation change.

Only one gesture runs at a time; overlap returns 409. Manual pointer and key
input is paused during that gesture. **Automation → Stop Agent Action** or
Command–Escape cancels it; disconnect, sleep, rotation and loss of control
also invalidate it. Cleanup only targets the captured session, never a newly
connected one. An overflowing native input queue cancels its session and releases
input during teardown. Already-queued one-shot commands cannot be undone.

`accepted` means input was queued, **not that the UI reached the desired state**.
The API does not silently retry commands after failures. Poll readiness and
observe again before choosing what to do next.

## Action plus observation

All `/v1/actions` operations except `release` accept `observeAfter: true` and
optional `observationTimeoutSeconds` (0.1–5, default 2; requires `observeAfter`).
App launch/terminate use their existing separate endpoints and still require a
separate screenshot. Existing action calls keep their behavior when the option
is absent. Actions return a unique `actionID`, host Unix `queuedAt` timestamp,
and `dispatchStatus`. The ID is a receipt, not an idempotency key or query handle.

```json
{"op":"tap","x":0.5,"y":0.4,"sessionID":"<observed session UUID>","observationID":"<observed geometry ID>","observeAfter":true,"observationTimeoutSeconds":2}
```

With observation enabled, the server inserts a FIFO marker after the native
input sequence (including touch/key release). It waits at most 5 seconds for
that marker. `dispatchStatus: "dispatched"` means the input transport operations
finished, **not that iOS applied them or that the intended UI appeared**.
`dispatchedAt` is host Unix seconds when the native marker was processed;
`dispatchConfirmedAtMonotonicSeconds` is when the Mac app received confirmation.
All clocks are on the Mac, not the iPhone or glasses.

Only a frame with a newer ordinal and a decode timestamp strictly after that
confirmation qualifies for the returned observation. Fresh observations include
`status: "fresh"`, `timedOut: false`, the usual PNG/geometry/session metadata,
`frameReceivedAt` (host Unix seconds), `frameReceivedAtMonotonicSeconds`, and
`frameTimestampSource: "host_decode"`. These timestamp fields also appear on
ordinary screenshots. Use monotonic timestamps for elapsed time; wall-clock
adjustments do not affect deadlines. A freshly decoded frame may still contain
buffered pre-action pixels and must be inspected.

A static display may legitimately emit no newer frame. In that case the response
retains the action receipt and `dispatchStatus: "dispatched"`, with
`observation: {"status":"timed_out","timedOut":true}` and no image. Do not retry
the action just because an observation timed out. `dispatchStatus: "failed"`
means the input sequence failed/closed before its marker; partial input may
already have been sent. `"unknown"` means dispatch could not be established
(including cancellation, unavailable marker, or `dispatchTimedOut: true`).
Observation can also report `cancelled`, `session_changed`, `unavailable`,
`action_interrupted`, `dispatch_failed`, `dispatch_unavailable`, or `not_attempted`.

One agent action owns input through its observation wait. Screen-changing app
requests are refused during that period; input actions are also refused while
launch/terminate runs. App listing remains independent. Stop Agent Action or
Command–Escape invalidates the wait and requests input release. Disconnect,
access revocation, and request cancellation still stop work; queued one-shot
commands cannot be undone. Allow 25 seconds for combined calls, and always
observe before retrying a transport failure that prevented a response.

## Connection event history

`GET /v1/status` adds `eventCursor`, `eventTypes`, and `lockState: "unknown"`.
Use that cursor to start observing **future** transitions, or `GET /v1/events`
to retrieve the currently retained history. History is independent of whether
a mirror connection is active and spans USB/Wi-Fi reconnects while the app runs.
It remains in memory only and is bounded to 256 entries.

`GET /v1/events?afterCursor=<cursor>&event=firstFrame&timeoutSeconds=5`
waits for matching entries after the cursor. `event` is optional. Timeout is
0–5 seconds (default 0); a nonzero timeout requires `afterCursor`. Four event
readers at most may run together; excess readers get 429. No polling request
creates or changes a device connection.

Each entry has `cursor`, `type`, `observedAt` (host Unix seconds),
`monotonicSeconds` (host uptime), and optional connection `sessionID` and
`transport`. Types are `opening`, `transportChanged`, `firstFrame`, `closed`,
`usbRemoved`, `usbReturned`, `wifiOnly`, `wifiLost`, `usbMonitorUnavailable`,
`videoStalled`, `startupTimeout`, `nativeFailure`, `manualReconnect`, `stopped`,
`sleeping`, and `waking`. `firstFrame` marks the Mac app observing its first
decoded picture in that connection, not an exact device-side frame timestamp.

Responses include `events`, `nextCursor`, optional `oldestCursor`, `gap`,
`timedOut`, and `lockState`. Advance to `nextCursor`, including when a filtered
read returns no events. `gap: true` means the requested history was evicted or
the cursor belongs to another app run; retained entries are returned for
resynchronization. An initial read also reports a gap if older entries have
already been evicted. Malformed or future cursors are rejected.

**Screen lock is not detected.** Neither connection loss, a black image nor
rotation lock becomes a screen-lock event. Timing reports are Mac observations;
no events can establish what occurred on a phone while it was unreachable.

The stdio bridge serves requests serially. Event waits are deliberately limited
to 5 seconds; request cancellation notifications are not an immediate abort.
The app's visible Stop and access-revocation controls remain authoritative.

See [focused validation and device checks](AUTOMATION-OBSERVATION-QA.md).

## Current boundaries

- Coordinate/HID control, not an iOS accessibility tree or XCTest assertions.
- No install, uninstall, arbitrary shell, unlock or credential API. Install your
  development build with your existing Xcode/Flutter tooling, then launch it by
  bundle ID.
- No automatic clipboard sync, remote network listener, workflow runner or LLM
  backend. Codex/the client supplies the agent loop and its own permissions.
- Avoid opening the iPhone Camera app while mirroring: the mirroring service
  conflicts with camera use, and the phone's preview can stay black afterwards.

## Device checks

1. Open Settings, enable access, request status and a screenshot. Confirm
   screenshot dimensions/orientation and that bezel/chrome are absent.
2. Tap a harmless navigation item, swipe a list, and verify each new screenshot.
3. Focus Settings search, type a disposable query, press Backspace/Enter, then
   clear it. Text paste may invoke an iOS paste permission prompt.
4. In an app that supports rotation, rotate both directions, observe again and
   test an off-center tap. Send an old observationID and expect 409.
5. Start a long swipe and press Stop Agent Action; ensure no held contact remains.
   Repeat with disconnect/reconnect; an old sessionID must be rejected.
6. List apps; launch Settings (`com.apple.Preferences`), terminate it, then
   launch it with `restart: true`. Verify each step with a screenshot.
7. Press volume up and down (the volume indicator appears), then lock and
   unlock by hand; control must resume.
8. Disable access; the listener and discovery file must disappear. Relaunching
   the app must leave access disabled.
