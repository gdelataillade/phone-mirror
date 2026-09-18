# PhoneMirror

A native macOS 27 open-source preview for viewing and controlling a USB-connected,
unlocked iPhone on iOS 27. SwiftUI/AppKit interface, VideoToolbox decoding, Metal
presentation, and a statically linked Rust CoreDevice backend.

This is an early implementation, not a finished replacement for Apple's iPhone
Mirroring. See [VALIDATION.md](VALIDATION.md) for what has actually been tested.
Built for personal and educational use, including experimenting with iPhone
mirroring in the EU. This is an independent project, unaffiliated with Apple.
It relies on developer services that can change between OS releases.

The current preview supports live USB video, mouse and keyboard input, explicit
text paste, Home/App Switcher controls, remote rotation, PNG screenshots, silent screen recording, and automatic reconnect.
Static-screen pauses are distinguished from stalled decoding using device liveness
and pipeline counters. Other video interruptions remain under investigation. Audio, Wi-Fi and controlling
a locked iPhone are not supported.

## Run

Build from source using the steps below, then open `build/PhoneMirror.app`,
connect your iPhone by USB, unlock it, and choose
**Mirror iPhone**. Use **Refresh devices** to discover the phone initially.
After connecting, the app automatically retries the same phone if USB or video
is interrupted. Disconnect (or **Stop reconnecting**) cancels those retries. Reattaching the selected iPhone bypasses the retry countdown.

The Mac and iPhone must already trust each other. Developer Mode must be enabled,
and Xcode 27 must have prepared the device with compatible developer services.
If preparation is missing, open the device in Xcode's Device Hub first.

The app installs no iPhone companion or WDA runner. The first build targets Apple
silicon; audio playback and Wi-Fi are not included.

## Controls

| Action | Control |
| --- | --- |
| Tap, double-tap, hold, drag | Mouse in the mirrored picture |
| Scroll | Mouse wheel or trackpad over the picture |
| Keyboard | Click the picture to focus it, then type |
| Save screenshot | Camera button or Command–S |
| Start/stop recording | Record button or Shift–Command–S |
| Copy screenshot | iPhone → Copy Screenshot, or Shift–Command–C |
| Home | Bottom toolbar or Shift–Command–H |
| App Switcher | Bottom toolbar or Shift–Command–A |
| Paste text | Edit → Paste Text to iPhone, or Command–V |
| Release held input | Command–Escape |
| Always on Top | Header pin, Window → Always on Top, or Option–Command–T |
| Fit window | iPhone → Fit Window to iPhone, or Command–0 |
| Rotate iPhone right | Bottom toolbar rotate button, or Option–Command–Right Arrow |
| Rotate iPhone left | iPhone → Rotate Left, or Option–Command–Left Arrow |
| Reconnect now | Top-right refresh arrow, reconnect screen, or Shift–Command–R |
| Disconnect | Top-right close button or Shift–Command–D |
| Connection diagnostics | iPhone → Connection Diagnostics, or the connection screen |

Always on Top keeps the mirror above ordinary windows on the current desktop.
The highlighted header pin indicates that it is enabled. The preference is remembered
across launches and works while disconnected too. It does not move the window to
other Spaces or place it above system dialogs and other apps’ full-screen Spaces.

Screenshots contain only the iPhone picture, cropped and rotated like the live view,
at the received stream resolution (not necessarily the iPhone’s full native resolution).
Save freezes the picture when you press the camera button, before you choose a PNG
file location. Copy places that image on the Mac clipboard. No capture is uploaded,
and no Mac screen-recording permission is needed. Capture is unavailable while
connecting, reconnecting or waiting for rotation.

Screen recording saves an H.264 QuickTime `.mov` containing only the iPhone image,
without audio, at up to 30 fps. Choose a destination first; recording starts after
Save. A red Stop button and elapsed timer stay visible while recording. Press Stop
or Shift–Command–S to finish. The starting orientation sets the movie dimensions;
subsequent rotations fit inside that canvas with black bars rather than stretching.
Start in landscape if most of your recording will be landscape.

Disconnecting, losing the video connection or putting the Mac to sleep stops and
finalizes the current recording; reconnection never resumes capture automatically.
Normal Quit waits for the movie to finish. Existing destination files are replaced
only after successful encoding. If moving the completed movie fails, the app reports
its temporary recovery path. Force Quit, crashes, disk exhaustion and power loss may
leave an incomplete movie; crash recovery and audio recording are not implemented.
Recording uses a bounded frame queue and may drop frames under load. Static screens
retain their elapsed duration.

Paste is an explicit, one-time transfer of up to 64 KiB of UTF-8 text. It replaces
the iPhone clipboard and sends its Paste command. There is no background clipboard
sync. Hardware typing uses the iPhone's hardware-keyboard layout; configure it to
match the Mac for punctuation and non-US layouts. Mac composition/IME forwarding
and Caps Lock state synchronization between devices are not implemented. Use
explicit paste for composed text. Multi-touch and pinch gestures are not included.

Input follows the picture actually displayed. Clicks in letterboxing are ignored;
drags that leave the picture clamp to its edge. Pointer movement is coalesced to
60 updates per second. Long scrolls start another swipe when they reach an edge,
and Mac momentum is not replayed after the iPhone begins its own inertia.

Command–A/C/X/Z and other non-app shortcuts go to the focused iPhone picture.
Command–V pastes Mac text explicitly. Quit, Hide, Minimize, window controls and
PhoneMirror's own shortcuts stay on the Mac. Modifier releases after focus loss
cannot generate a new modifier press, and held-key repeats cannot restart input
after reconnection. The two Shift/Option/Control/Command keys remain distinct.

The rotate button sends a real 90-degree rotation request to the iPhone, so its
screen and the mirrored picture rotate together without moving the hardware.
The foreground app decides whether to lay out in landscape; some screens stay
in portrait. The app does not toggle the iPhone's rotation-lock setting.

Rotation cancels ongoing input. The button waits for a fresh frame showing the
changed orientation, and reports when the phone keeps its current orientation.
Touch uses the same orientation as the displayed image. CoreDevice may keep
portrait-sized encoded frames in landscape; the renderer rotates those pixels
and swaps the presentation dimensions. Already-oriented landscape buffers are
not rotated again. The window fits automatically between portrait and landscape;
Command–0 fits it manually. Unknown orientation keeps video visible with touch disabled.

Losing app or window focus, resizing, rotation and explicit release clear held input.
Missing or unhealthy video disables control. On an unchanged screen the iPhone can
legitimately stop sending new pictures: the last picture remains usable only while
new orientation-service responses confirm liveness and the pipeline has no pending
frames or recorded integrity/decoder errors. Cached health snapshots cannot keep it alive.
The app restarts an unhealthy session after one second without decoded output, with
retry delays of 1, 2, 4, 8, 16, then at most 30 seconds. Cleanup runs during that
delay. USB detach notifications detect cable loss without waiting for stale video;
reattachment and **Reconnect now** skip backoff. The new stream still has to open. A connection must remain live
for ten seconds to reset that delay. Mac sleep pauses connection attempts; waking
resumes the selected phone unless you disconnected.

Disconnect and quit cancel pending work and stop only this app's owned media session. The physical
iPhone stays visible and unlocked; this preview does not unlock or hide its screen.

## Build from source

Requirements: Xcode 27, an Apple silicon Mac on macOS 27, and Rust 1.95 or newer.
Install Rust using [rustup](https://rustup.rs/) and ensure `cargo` is on your PATH.
Open Xcode once to finish its initial setup, and select Xcode's developer tools
in Xcode → Settings → Locations. The Command Line Tools package alone is not enough.

```sh
git clone https://github.com/gdelataillade/phone-mirror.git
cd phone-mirror
./scripts/build.sh
./scripts/test.sh
open build/PhoneMirror.app
```

Builds use the checked-in Cargo lockfile, vendored idevice source, and system Apple
frameworks. Cargo needs internet access for the first dependency download. The app
has no Python, Homebrew, Appium, or Rust-toolchain runtime dependency. It is locally
ad-hoc signed. This repository distributes source; it does not include a notarized
downloadable app. Build locally for this preview.

Open `Package.swift` in Xcode to explore the Swift targets. Build the Rust library
with the script before building the executable target in Xcode.

## Structure

- `Sources/PhoneMirror`: native window, input, lifecycle, decoder and GPU renderer.
- `Sources/MirrorCore`: connection policy, decoded-video watchdog, coordinate
  transformations, physical keyboard state and bounded scroll gestures.
- `Sources/CMirror`: the narrow C ABI. Events are polled and freed explicitly;
  native code does not retain a Swift callback pointer.
- `Backend`: USB transport, media negotiation, bounded HEVC delivery, feedback,
  ordered input and session-specific shutdown. `probe` checks received access units
  without decoding or saving images.
- `Vendor`: pinned idevice source, selected MIT reference patches and provenance.
- `Tests` and `Backend/tests`: lifecycle, video watchdog, input state, orientation,
  geometry and packet-integrity tests.
- `Diagnostics`: local video and connection fault-injection probes, without input
  commands or screen recording.

## Engineering notes

Each connection has a separate Swift generation and Rust runtime. The event queue
holds at most 16 items, decoded video keeps only the latest pixel buffer, and the
input queue holds at most 64 commands. If input overflows, the session cancels and
attempts to release all held input; actions are never replayed after reconnect.

HEVC packet loss or encoded backpressure discards the incomplete picture and waits
for a random-access frame. The backend sends keyframe requests and stops with an
explicit error if recovery fails. The app then closes the old native worker before
creating a new session, decoder, input queue and view. Keyframe-only recovery did
not restore a deliberately overflowed stream on the test phone; full reconnection
did. A short HID authentication delay runs independently from media reception.
Feedback goes to port 50001, the device feedback endpoint specified in the offer;
it is distinct from the incoming RTP source port.
Apple's long-term-reference video mode is disabled for compatibility with the decoder.

This preview uses primary display ID 1 and obtains video dimensions from the HEVC
configuration. It queries device orientation every 500 ms on an independent task,
so a slow reply cannot block media reception. A codec change requires an orientation
query begun after that change before touch is enabled; orientation travels with each
frame across the native boundary. Video feedback has a bounded response deadline
so an unresponsive adapter cannot indefinitely prevent session cleanup.
Both landscape directions, their touch mapping, and returning to portrait were
checked on the iPhone 17. Other devices and stream configurations, upside-down
orientation, and extra padding outside the codec conformance window need further
hardware verification.

There is no analytics service or default screen/keystroke recording. `PM_TRACE=1`
enables local protocol diagnostics containing sender ports and discontinuity reasons,
not screen pixels, clipboard contents, typed text, or pairing records.
`PM_TRACE_ORIENTATION=1` additionally logs current/non-flat orientation and the
rotation-lock flag, without screen content.

## Device diagnostics

Open **iPhone → Connection Diagnostics…** to inspect current counters and recent
connection events, then **Copy Report** or **Save Report…**. Reports retain closed
session counters across reconnects and up to 60 recent events. They include app/OS
versions, packet/frame counts, decode timing, queue overloads, feedback failures,
orientation response timing and relative event times. They exclude device names,
identifiers, paths, raw error strings, screen contents, typed text and clipboard data.
Nothing is uploaded automatically; reports are kept in memory unless you export them.
Timing counters describe this pipeline, not end-to-end latency or Mac rendering.

Close/disconnect the app before running these against an unlocked USB iPhone:

```sh
./scripts/diagnose.sh --seconds 120
./scripts/diagnose-connection.sh
./scripts/diagnose-connection.sh --video-stall
./scripts/diagnose-connection.sh --manual-reconnect
./scripts/diagnose-connection.sh --seconds 600
```

The first counts decoded frames. The second terminates a native session, checks
that the real app coordinator reconnects, then verifies Stop cancels a pending
retry. The third deliberately blocks the decoder consumer for one second to fill
the bounded queue, and checks that automatic reconnection restores decoded video.
The manual-reconnect option checks a restart while live. The timed run observes the
real coordinator for 10 minutes, prints sanitized counters, and fails if reconnection,
decoder errors or queue overload occurs. These do not replace physical cable and
sleep/wake tests.

To check video resuming after an idle screen, open a harmless Settings list and run
`./scripts/diagnose.sh --seconds 30 --scroll-at 11`. This explicitly sends one swipe
on the phone at 11 seconds; all other diagnostic modes above send no input.

For the raw video layer alone, `./scripts/diagnose.sh --seconds 45 --pause-at 15
--pause-for 1` injects the same backlog without the app coordinator. It currently
exits unsuccessfully because keyframe feedback alone does not restore the stream.

Future work: longer device validation, measured end-to-end latency, stronger
orientation/lock-state observation, audio, and then Wi-Fi. The app does not infer
that a phone is locked solely because video stops.

Dependency provenance and notices are in [Vendor/README.md](Vendor/README.md).

## License and privacy

PhoneMirror is [MIT licensed](LICENSE). Vendored code retains its original notices.
See [SECURITY.md](SECURITY.md) for reporting issues and keeping device information,
pairing records and credentials out of commits. The repository runs a secret scan
on pushes and pull requests; review screenshots and diagnostics manually before sharing.

## App icon

The supplied artwork lives in `Resources/AppIcon.png`. The normal build runs
`scripts/build-icon.sh` to generate the standard macOS icon sizes and bundle
`AppIcon.icns` before signing. Replace the source PNG to change the icon; no
additional image tooling or runtime dependency is required.
