# Local automation API

iPhoneMirror exposes its existing USB session to local tools. Open the app,
connect an unlocked iPhone, then choose **Automation → Enable Agent Access**.
The banner shows when access is enabled and when an agent gesture is running.
**Stop Access** revokes access and cancels the current gesture. Access starts
off on every app launch. Nothing is sent to an AI provider by the app itself.

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
| `GET /v1/status` | Connection/control readiness, sessionID, observationID, dimensions, decoded FPS, busy flag and capabilities |
| `GET /v1/screenshot` | Upright PNG as base64 `image`, mimeType, width/height, sessionID, observationID, frameID and ageSeconds |
| `GET /v1/screenshot?format=png` | The same PNG as the raw response body; metadata in `X-iPhoneMirror-Width`, `-Height`, `-SessionID`, `-ObservationID`, `-FrameID` and `-AgeSeconds` headers |
| `POST /v1/actions` | Validated input action; returns accepted and a sessionID when connected |
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
actions after reconnect or orientation/geometry changes. These guards do not
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
