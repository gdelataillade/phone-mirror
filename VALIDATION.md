# Implementation and validation record

18 September 2026 — personal preview with input and remote rotation controls.

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

The decoded-video watchdog restarts after one second without fresh output, or
25 seconds if a session never produces a picture. Clearing the decoder mailbox
during an error does not reset this deadline. Controls require a current picture.
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

Paste, Home, App Switcher, held-input edge cases and longer sessions still need
comprehensive on-device QA. Passing checks on one phone do not establish general
control accuracy across other devices and apps.
Audio, Wi-Fi, notifications, notarization and public distribution remain out of scope.

## Earlier baseline, 16 September

Receive-only probes delivered 745 complete HEVC access units in 25.1 seconds and
998 in 30 seconds. The first app displayed the phone, but a decoder probe later
stalled after nine decoded frames with zero decoder errors. Moving control setup
before media, bounded queues, keyframe feedback and decoder work were implemented
then; the phone became unavailable before those changes could be tested. The
results above replace that earlier unverified recovery status.
