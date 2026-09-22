# Development notes

[Back to iPhoneMirror](../README.md)

Commands below run from the repository root.

## Structure

- `Sources/iPhoneMirror`: native window, input, lifecycle, decoder and GPU renderer.
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

Dependency provenance and notices are in [Vendor/README.md](../Vendor/README.md).


## App icon

The supplied artwork lives in `Resources/AppIcon.png`. The normal build runs
`scripts/build-icon.sh` to generate the standard macOS icon sizes and bundle
`AppIcon.icns` before signing. Replace the source PNG to change the icon; no
additional image tooling or runtime dependency is required.
