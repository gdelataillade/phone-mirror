# Implementation and validation record

18 September 2026 — personal preview with input and remote rotation controls.

## Reliability and connection diagnostics

The previous watchdog treated every one-second gap in decoded pictures as a
failure. On the physical test phone, a static screen repeatedly stopped producing
video after roughly 418 frames while orientation queries still succeeded. The
coordinator consequently reconnected despite zero decoder errors, skipped outputs,
queue overflows or stream discontinuities. A raw receive/decode experiment with
one explicitly requested Settings scroll resumed on the same connection after a
**3.844-second output gap**, decoded 1,164 frames in 30 seconds, and reported no
decoder errors, skips, overflows or discontinuities. This establishes a false
reconnect condition; it does not explain every earlier interruption.

- The watchdog now accepts idle video only with newly completed device queries,
  matching assembled/queued/decoded counters, and no recorded stream, feedback or
  decoder failure. Repeated cached telemetry cannot extend this deadline. Startup
  timeout, fast USB-loss detection and the 1/2/4/8/16/30-second retry schedule remain.
- Orientation queries run separately from media reception and feedback. A codec
  change disables picture input until an orientation query begun after that change
  completes. Timeout/cancellation drops the service connection rather than reusing
  a possibly late reply. Feedback calls time out instead of indefinitely blocking
  session cleanup.
- **Connection Diagnostics** is available from the iPhone menu and connection
  screen. Copy/save exports retain numeric counters and recent fixed-label events
  across reconnects. No device identity, raw errors, media, clipboard or input is
  included. The report has been opened and saved through the actual macOS UI.
- **79 automated tests pass: 41 Rust and 38 Swift.** Added checks cover idle video
  with fresh versus cached liveness, pipeline errors and pending frames, missing
  first pictures, delayed orientation, cancellation, feedback timeout, bounded
  report history, and exclusion of free-form identity from version fields.
- The production build and ad-hoc signature verification pass. A source-only
  Gitleaks scan and a scan of the UI-exported report found no leaks.
- A **600-second run of the actual coordinator and decoder** completed on one
  connection: **12,164 decoded frames**, zero decoder errors/skipped outputs,
  zero queue overflows/discontinuities/feedback failures, and 1,200 successful
  orientation queries. The maximum interval between decoded outputs was
  **54.977 seconds** during idle video; new pictures resumed without reconnection.
  The session closed cleanly. This diagnostic does not exercise Metal rendering
  and is not a substitute for multi-device or physical sleep/wake validation.
- The forced one-second decoder-backlog check still passed: the queue overflow
  was recorded, the coordinator closed the unhealthy session around elapsed 5s,
  and a new connection restored decoded video around 6s. Stop during the next
  backoff kept the coordinator idle for twelve seconds; all native work closed.
- In the actual Mac window, Settings remained connected at zero FPS, scrolling
  from the Mac resumed live video, and manual reconnect restored the picture.
  The live diagnostics panel showed two attempts (initial plus manual) and kept
  the previous session's counters. The updated app was left connected.

Liveness establishes that the device control path responds; it is not an independent
pixel comparison. A silent encoder-only failure without an integrity signal may
still require **Reconnect now**. This prototype continues to require an unlocked
iPhone. Physical cable and sleep/wake checks remain separate from injected failures.

## Public source preparation

The publication build and signature verification passed. **69 tests pass**:
37 Rust tests (including two checks for the provenance-pinned OPACK module) and
32 Swift tests. The USB runtime implementation is unchanged by the publication
cleanup. See [SECURITY.md](SECURITY.md) and [PUBLICATION-AUDIT.md](PUBLICATION-AUDIT.md)
for the separate source privacy review. There is no notarized binary release.

## Remote rotation button

- The bottom toolbar now has **Rotate iPhone right**. The iPhone menu includes
  both directions, with **Option–Command–Right/Left Arrow** shortcuts.
- Commands use CoreDevice's device orientation service. They release held input
  first and run on a separate service connection so a rotation request does not
  block video reception. Commands are not replayed after reconnecting.
- Repeated clicks are suppressed while a request is pending. Completion requires
  a newer usable frame after acknowledgment, showing an orientation change. An
  unchanged orientation after four seconds produces a message; a command failure
  reports an error without deliberately tearing down otherwise healthy video.
- **Live device discovery corrected an earlier assumption:** this iPhone retains
  portrait-sized encoded pixels while the content rotates inside them. Matching
  orientation to encoded aspect ratio incorrectly disabled touch. Presentation
  now rotates natural portrait buffers and uses the resulting dimensions for
  window fitting and inverse touch mapping. Landscape buffers that are already
  oriented are handled separately.
- Live Safari checks passed for both landscape directions, an off-center tap in
  each direction (website navigation and the Safari address bar), and returning
  to portrait. The Mac window followed orientation automatically. The user also
  confirmed that the **physical iPhone screen rotated while the phone stayed still**.
- The user confirmed Settings typing, Command–A, Backspace and scrolling work well.
- **67 automated tests pass:** 35 Rust and 32 Swift. Added cases cover rotation
  acknowledgment versus fresh frames, duplicate requests, timeout, cancellation,
  natural portrait rendering/input agreement, and avoiding double rotation of
  already-oriented landscape pixels.

Intermittent video interruptions occurred during the live checks; automatic
reconnection restored the picture. The phone remained unlocked and connected
according to the user. Rotation worked again after recovery. An isolated
30-second receive/decode diagnostic then produced **1,635 decoded frames, zero
decoder errors and no skipped outputs**, with a maximum output gap of **0.617s**,
including startup. A subsequent toolbar rotation and return-to-portrait shortcut
worked in the app. The interruption cause is not established; this does not
demonstrate a stall-free long session or rule out a rotation-related problem.

To reproduce: keep the phone stationary, unlock it, open Safari, and click the
bottom rotate button. Check both the real screen and the Mac window. Use the
left/right shortcuts to test the other direction and return to portrait. Tap a
known control away from the center after each turn. Test portrait-only apps and
rotation lock separately: iOS/app restrictions may prevent the requested layout.

## Input and rotation update

- Added an explicit physical-key state machine. It distinguishes left/right
  modifiers, releases keys before modifiers, ignores stale repeats after a release,
  and never interprets a modifier release after focus loss as a new press.
- Mac app shortcuts stay local; other Command shortcuts reach the focused phone.
  Losing app/window focus, resizing, rotation and Command–Escape release input.
  Each view and delayed gesture stays bound to its original connection.
- Initial clicks in letterboxing are rejected; ongoing drags clamp at the picture
  edge. Motion is coalesced to 60 updates per second. Scrolling starts another
  swipe when it reaches an edge and leaves post-release inertia to iOS.
- The initial implementation required matching encoded frame geometry and orientation metadata. A geometry
  change releases input and waits briefly before accepting new gestures. The
  native orientation reader prefers current orientation, with the last non-flat
  orientation as a fallback. Unknown orientation preserves video but disables
  picture input. The remote rotation check above supersedes its encoded-aspect
  assumption and verifies both landscape input transforms.
- The window fits when the encoded video changes between portrait and landscape.
  **Command–0** also fits it manually.
- Production build and ad-hoc signature verification succeeded. **62 tests pass**:
  32 Rust media, one USB presence, two native orientation, and 27 Swift tests.
  New tests exercise stale repeats, modifier transitions, geometry mismatches,
  edge-clamped drags, resize invalidation and long scrolling.

At that stage the build opened and displayed live video from the physical iPhone. A
portrait tap opened Settings search during the baseline check. The phone then
locked during implementation, so typing, paste, scroll, rotated taps, automatic
window fitting, Home and App Switcher were not yet verified. See the newer results
above for typing, scrolling, rotation, fitting and rotated taps. Paste, Home and
App Switcher still need comprehensive validation.
Automated coordinate/state tests do not establish on-device control accuracy.

For the next live check, unlock the phone and keep it awake:

1. In Settings, click Search in the mirrored picture. Type `bluetooth`, use
   Command–A and Backspace to clear it, then paste a harmless accented string
   with Command–V. Do not change any setting.
2. Scroll a long Settings list in both directions. Drag within the picture, then
   beyond its edge and release. Try a click in the black border: it should do
   nothing.
3. Use an app that supports landscape, such as Safari with a harmless page.
   Physically rotate left, right, then back to portrait. Check window fitting and
   tap targets away from the center in each orientation. Portrait-only screens
   are not sufficient to validate landscape coordinates. Rotation lock must be
   off for this test; the app does not change it.
4. Resize the Mac window and press Command–0. Repeat taps near the picture edges.
   While typing in Search, switch away from PhoneMirror and release Shift; return
   and check that ordinary typing is not shifted or repeated unexpectedly.
5. Try Home and App Switcher, then return to Settings. Use Command–Escape during
   a gesture and confirm there is no continuing touch or held key.

Hardware typing follows the iPhone's configured hardware-keyboard layout.
Mac IME/composition forwarding, Caps Lock state synchronization between devices,
and multi-touch/pinch gestures are not implemented. Unicode text can be transferred
using explicit paste; that path also needs live validation.

## Faster retry update

- The user confirmed physical reconnection worked with the preceding build, but
  reported an approximately eight-second wait.
- Decoded-video loss detection is now one second (previously four). A separate
  USB notification listener detects removal and reattachment without waiting for
  the frame timer. Returning USB skips the current countdown for the selected
  phone; it never starts another phone or overrides Stop.
- Retry intervals are 1, 2, 4, 8, 16, then 30 seconds. Cleanup runs inside the
  interval, and the best-effort owned media-stop request waits at most 300 ms.
  Cancelling during connection setup now interrupts pending service calls too.
- Reconnect now is available in the top toolbar, the recovery screen and via
  Shift–Command–R. It skips the countdown, resets the backoff sequence, and waits
  for the old worker to close before opening another session.
- All **50 automated tests pass**: 32 media, one USB presence filter, 17 Swift
  geometry/lifecycle/watchdog tests. The added cases cover cleanup deadlines,
  immediate retry, repeated clicks, Stop and sleep overriding manual retry, and
  ignoring other devices, Wi-Fi and duplicate USB notifications.
- The faster forced-overflow diagnostic recovered: closing at elapsed 6s,
  reconnecting at 7s and decoded video restored at 8s. Stop still prevented retries.

- Manual reconnect on the connected phone restored decoded video in **0.420s**.
  The actual window exposes the new toolbar button and remained live after clicking it.

The user subsequently confirmed that the faster reconnect build works well.
The measured timings above are native cancellation/decoder-stall diagnostics,
not unplug-to-picture measurements. Physical cable timing was not measured by the
agent. The handshake and required cleanup prevent a guarantee of instantaneous video.

## Earlier stability checks (before faster retry)

Environment: macOS 27.0, Xcode 27.0, physical iPhone 17 on iOS 27.0, trusted USB
connection and an unlocked phone. No iPhone companion or WDA runner was installed.

- The production app builds and opens. The updated app visibly displays the live
  iPhone through VideoToolbox and Metal.
- A 120-second decode diagnostic produced **5,192 decoded frames, zero decoder
  errors and zero skipped outputs**. The largest interval between outputs was
  **0.760 seconds**, including startup. This is not end-to-end latency.
- A separate 30-second diagnostic decoded 1,367 frames without errors.
- The actual app coordinator, linked to the real native session and decoder, was
  exercised by `scripts/diagnose-connection.sh`: intentional native cancellation
  was followed by a fresh session and decoded video. Stop during the next retry
  kept the coordinator idle for twelve seconds, and all native work closed.
- `scripts/diagnose-connection.sh --video-stall` blocked the decoder consumer for
  one second. Native tracing confirmed that the bounded queue filled. The app
  detected stale output, closed the old session, retried and restored live video:
  closing around elapsed 9s, connecting around 10s, live again around 11s.
  Stop during a subsequent retry also passed.
- `scripts/test.sh`: **32 Rust media tests and 13 Swift tests passed before the faster retry update**. Swift tests
  cover four geometry cases, six connection lifecycle cases and three decoded
  video watchdog cases. Lifecycle tests include same-device retries, capped
  backoff, late callbacks, Stop, sleep/wake ordering and cleanup before reopening.

Injected native cancellation is not a physical unplug. Simulated lifecycle events
are not proof of Mac sleep/wake. See the device checklist below for remaining QA.

## Recovery behavior and limits

A connected session retains the selected device identifier across interruptions.
Retry delays are 1, 2, 4, 8, 16 and then 30 seconds, reset only after ten seconds of
live output. Disconnect and quit clear connection intent. Mac sleep preserves
intent but suppresses attempts; wake resumes once the old worker has closed.
Each attempt owns a fresh decoder, bounded input queue and input view. Old native
callbacks cannot update a new attempt, and queued commands are not carried over.

The decoded-video watchdog restarts after one second without usable output or
verified idle liveness, or 25 seconds if a session never produces a picture.
Clearing the decoder mailbox does not reset this deadline. Controls require a
picture backed by fresh output or healthy idle liveness.
A decoder reset waits for a sync frame before accepting predicted pictures.

**Keyframe-only recovery is still unreliable on this phone.** The raw diagnostic
with a one-second consumer pause overflowed the queue and did not resume, despite
keyframe feedback. The new app-level full-session restart recovered that exact
failure in the live diagnostic. Expect a visible interruption during recovery.

Feedback now targets the device endpoint specified in the offer (port 50001),
matching the pinned reference implementation. The incoming RTP source port is
usually different. Earlier baseline runs still stalled after 520 and 420 decoded
frames; those observations do not establish a single root cause. The old claim
that decoder initialization alone caused the stall remains a hypothesis.

The app does not equate missing video with a confirmed locked phone. It asks the
user to check USB and unlock the phone, and reports its actual retry state.
Locked-phone mirroring and unlocking the phone are outside the supported scope.

## Manual device checklist

Open `build/PhoneMirror.app`, connect by USB, unlock the iPhone and choose
**Mirror iPhone**. Keep a harmless screen such as Settings visible.

1. **Cable:** unplug briefly, reconnect and unlock. Also leave the cable unplugged
   until the countdown reaches eight seconds, then reconnect. The app should show a
   retry state and resume without clicking Mirror iPhone. Repeat several times.
2. **Manual retry / Stop:** unplug and click Reconnect now during a countdown; the
   attempt should begin without waiting. Then unplug, wait for the retry state, choose Stop reconnecting, then
   reconnect the cable. No session should start until you choose Mirror iPhone.
3. **Lock:** lock for ten seconds and unlock. The app may lose video while locked;
   it should resume after unlocking without requiring a manual connect.
4. **Sleep:** while mirroring, put the Mac to sleep, wake it and unlock the phone.
   Verify automatic recovery. Repeat after Disconnect: it should stay disconnected.
5. **Input safety:** while dragging or holding a modifier in a disposable local
   test, unplug and reconnect. Check that no action replays and no contact/key
   remains held. Device-side release is best effort if transport is already gone.
6. **Long run:** mirror for 30 minutes, including scrolling, animation and a static
   screen. Watch for corruption, stalls, reconnect loops or increasing memory.
7. **Idle display:** leave Settings untouched for at least 30 seconds. Zero FPS
   can be normal on a static screen; the connection should stay open. Then scroll
   from the Mac and verify that fresh pictures resume. Open Connection Diagnostics
   and check that this did not introduce another connection attempt.

Paste, Home, App Switcher, held-input edge cases and longer sessions still need
comprehensive on-device QA. Passing checks on one phone do not establish general
control accuracy across other devices and apps.
Audio, Wi-Fi, notifications and notarized binary distribution remain unsupported.
The source repository is public.

## Earlier baseline, 16 September

Receive-only probes delivered 745 complete HEVC access units in 25.1 seconds and
998 in 30 seconds. The first app displayed the phone, but a decoder probe later
stalled after nine decoded frames with zero decoder errors. Moving control setup
before media, bounded queues, keyframe feedback and decoder work were implemented
then; the phone became unavailable before those changes could be tested. The
results above replace that earlier unverified recovery status.

## Screenshot capture, 18 September

- Full test suite: 82 passing (41 Rust, 41 Swift). New PNG tests decode exported
  pixels to check all four orientations, already-oriented landscape, unknown
  orientation rejection and clean-aperture cropping.
- Release build and ad-hoc signature verification pass. No new Swift warnings.
- Live iPhone: Command–S and Shift–Command–C worked with the mirrored screen
  focused. Saved and clipboard PNGs were 1216 × 2656. The saved Settings image
  was visually inspected: no Mac window, toolbar or window letterboxing.
- Camera button opened Save; Cancel returned to mirroring and re-enabled capture.
- Test images remain outside the repository. No screenshot was published.
- Live landscape screenshots and protected-content behavior remain unverified.
  To check landscape, open a harmless Safari page, rotate using PhoneMirror,
  save a screenshot and verify its orientation in Preview. Return to portrait
  and repeat. Copy with Shift–Command–C, then use Preview → File → New from
  Clipboard to verify pasting. Captures use stream resolution, not a separate
  full-resolution device screenshot service.

## Screen recording, 18 September

- 85 automated tests pass (41 Rust, 44 Swift). Movie tests read exported H.264
  files, check video-only tracks, preserve two seconds of idle duration, decode
  a landscape image fitted to a portrait canvas and reject an empty recording.
- Live Start/Stop through Shift–Command–S produced a 15.16-second 1216 × 2656
  movie at 29.93 fps. Sampled frames were decoded and the first was visually
  inspected; a full FFmpeg decode completed without errors.
- Clicking Disconnect during recording finalized a second playable 13.03-second
  movie. Recording did not resume after reconnecting.
- Normal Quit during a static-screen recording finalized a 34.17-second H.264
  movie and exited the process. The updated app was reopened afterward.
- The recording UI showed a red Stop control and elapsed timer. Test media remains
  outside the repository and has not been published.
- The current writer uses AVFoundation compatibility APIs deprecated in macOS 27;
  the build succeeds with deprecation warnings. Migration to input receivers is
  future maintenance, not evidence of additional device validation.
- Manual QA still needed: start on a harmless Safari page, rotate both directions,
  stop and play the complete clip in QuickTime. Repeat with a brief USB unplug and
  Mac sleep. Confirm the saved clip stops at interruption and recording stays off
  after reconnect. Long recordings, disk-full paths and protected media remain
  unverified. Movies are silent; crash recovery is not included.

## Always on Top, 18 September

- Release build, signature verification and diff whitespace checks pass.
- Live header pin and Option–Command–T switch the mirror's actual window level
  between floating (3) and normal (0). Read-only window-order inspection while
  another app was foreground showed PhoneMirror above Finder when pinned and
  below Finder after unpinning.
- Enabled preference survived Quit and relaunch. Shortcut also worked with the
  mirrored iPhone focused. Screenshot Save remained accessible while pinned;
  Cancel returned to the connected mirror. App left pinned and connected.
- No new unit tests were added for this small AppKit preference; validation was
  performed in the built app. Other Spaces and full-screen apps were not tested.
- To reproduce: click the header pin, activate another ordinary window on the
  same desktop, then toggle off with Option–Command–T and activate that window
  again. Restart PhoneMirror to check preference persistence.

## App icon, 18 September

- Integrated the supplied square PNG without changing its artwork.
- Release build generates the ten standard iconset representations, including
  1024 × 1024, and packages AppIcon.icns via CFBundleIconFile.
- Verified plist syntax, decoded the resulting icns with iconutil, checked its
  largest representation, and verified the app signature. Restarted the app.

## Optional iPhone bezel, 18 September

- Added a dark rounded frame with a metallic edge, enabled by default. Toggle
  View → Show iPhone Bezel or Option–Command–B; the preference is saved.
- The view fits the current screen aspect ratio inside the frame. Touch uses the
  resized Metal surface; the decorative border is outside its bounds. Rounded
  screen corners reject initial taps. No simulated camera cutout is added.
- Screenshot and recording exporters still use the decoded stream directly and
  therefore exclude the decorative bezel.
- Release build, signature verification and all 85 existing tests pass. Live
  portrait appearance, opening Settings by tapping, toggling while the phone
  has keyboard focus, and Fit Window were checked. App left with bezel enabled.
- To complete visual QA, open a harmless landscape-capable app, rotate both ways,
  resize the window, and check edge taps and scrolling. Live landscape and saved
  captures with the bezel enabled were not rechecked in this pass.

## Window resize with bezel enabled — bug fix, 22 September

Rotating with the bezel enabled either did not resize the window at all, or left
it the wrong shape after rotating back (kept the prior orientation's width, only
grew height). Root cause: the resize math anchored on the video view's own AppKit
bounds, which is already a bezel-inset, aspect-fitted rect once the bezel is
shown, not the window's real available space. Fixed by anchoring on the window's
actual `contentView` bounds plus an explicit bezel inset instead. Verified live,
both rotation directions, bezel on and off, with window-scoped screenshots at
each step; no black margins, no stuck-at-wrong-size behaviour.

## Native macOS chrome, then reverted, 22 September

Replaced the custom header/footer bars with a native title bar (device name + iOS
version) and a unified NSToolbar, matching Simulator's look. This surfaced a
reproducible bug: SwiftUI Buttons and Menus hosted inside an NSToolbar do not
reliably dispatch clicks on this macOS 27 preview build — confirmed by screenshot
(toolbar collapsed into a single system overflow chevron at the window's 360pt
minimum width, swallowing even the "more options" menu). Trimming toolbar item
count did not resolve it; Home and other buttons still did not respond to clicks
even when directly visible, not overflowed.

Reverted the interactive controls to plain, always-visible buttons in the window
content (the pre-redesign structure), keeping only the native title bar/subtitle
and a transparent background. Confirmed live: all buttons (pin, bezel toggle,
mute, reconnect/disconnect/refresh, record, screenshot, rotate, home, app
switcher) respond to clicks again.

Separately, the same click-dispatch failure was confirmed in the standard macOS
menu bar's "iPhone" menu — including pre-existing items untouched by this work
(e.g. "Save Screenshot…"). Keyboard shortcuts for every menu command work
correctly; only mouse clicks on NSMenu items fail. Treated as an environment-wide
macOS 27 preview / SwiftUI `.commands` bridging bug, not an app defect — no
attempt was made to rebuild the menu bar in raw AppKit for what is very likely a
beta-OS issue. Keyboard shortcuts remain the reliable interface; the menu bar
mainly serves as shortcut documentation until this is fixed upstream.

## Audio playback, 22 September

Investigated feasibility (protocol reading, then a live capture-and-decode
prototype with throwaway Rust/Swift tools, deleted after use) before
implementing. Confirmed: the device's system-audio RTP stream is **AAC-ELD,
48000 Hz, stereo, 480-sample frames (10ms)**, unencrypted (`SRTPCipherSuite: 0`
in the device's own negotiated `streamConfig`), payload type 101. The raw RTP
payload decodes directly via `AudioConverter`/`AVAudioConverter` with
`kAudioFormatMPEG4AAC_ELD` — no header stripping, no magic cookie needed. Silent
periods send a constant 4-byte placeholder rather than real frames.

Implemented as a second, independent native poll queue (`pm_poll_audio`, its own
`mpsc` channel, its own Swift `DispatchQueue`) so audio decode can never wait on
video decode or the reverse, matching the existing independent-generation
architecture. Playback via `AVAudioEngine`/`AVAudioPlayerNode`. Muted by default;
explicit mute toggle and volume slider, both persisted and applied to each new
session.

One live bug found and fixed during bring-up: the audio RTP stream's actual SSRC
does not match the `RemoteSSRC` field in the device's `streamConfig` answer —
validating against it silently dropped every packet. Fixed by validating only
the RTP payload type (which did match), not SSRC.

Verified live: real audio (a YouTube video playing on the phone) confirmed
audible by ear through the Mac's speakers; mute/volume control confirmed
working. No audio/video synchronization is attempted; each stream plays
independently as it decodes. Not tested: interruption handling, backgrounding,
long-run stability, non-music audio sources.

## System-gesture shortcuts, 22 September

Reassigned Home (⌘1) and App Switcher (⌘2) from their previous shortcuts; both
use the pre-existing virtual-hardware-button mechanism (`indigo.send_button`,
Consumer usage 0x40) and are confirmed working live.

Added Spotlight (⌘3) and Control Center (⌘4) as new gestures, neither previously
implemented:
- Spotlight: a synthesized drag on the raw touchscreen surface from
  approximately (50%, 30%) to (50%, 55%) of screen height, using the same
  primitive that already powers scrolling. Confirmed working live.
- Control Center: tried the vendored protocol's dedicated
  `IndigoDigitizerEvent`/`DigitizerEdge` "edge-swipe system gesture" API first,
  never previously used by this app. Neither `DigitizerEdge::Top` nor `::Right`
  (both near the top-right corner) worked live. Switched to the same raw
  touchscreen-drag approach that worked for Spotlight instead, anchored near the
  top-right corner (94%, 3%) dragging down to (94%, 40%) of screen. Confirmed
  working live.

No new automated tests were added for audio or the gesture shortcuts; this is
live-hardware-dependent behavior, validated manually in the built app, same as
prior AppKit-preference features in this log.
