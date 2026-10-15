# Camera availability after mirroring

## Change

The old backend started audio/video with a 3,600-second timeout, then sent a
UUID-shaped stop request that the device does not accept. It discarded teardown
errors. Pulling USB also removes the connection needed for any explicit stop.

The backend now requests a 20-second RTCP timeout and validates the negotiated
timeout before accepting a stream. Session-owned receiver reports keep audio and
video alive once per second, including silent audio and static screens. Ending
the media loop ends keepalives; no detached keepalive worker survives cleanup.

This implementation uses **expiry, not an immediate remote stop**. On the tested
iOS 27 daemon, targeted stop requires numeric stream tokens, but start/status
replies do not expose a reliable token for every stream. The UUID request was
removed. A global stop after checking ownership is still a check-then-act race,
so the application never calls it. A trial of RTCP BYE did not remove the two
sessions immediately and was not retained.

A fresh, read-only status request at shutdown has a total budget of 2 seconds
over USB or 6 seconds over Wi-Fi. Final diagnostics survive the native worker's
join and distinguish absent, awaiting expiry, unreachable, timed out, unknown,
and rejected status. Absence is an observation at that instant, not physical
Camera verification. The UI explains the possible delay after Disconnect.

Wi-Fi continuation is unchanged: unplugging while Wi-Fi mirroring continues
does not end the session. Use Disconnect, or disable Use Wi-Fi When Unplugged.

## Reproducible checks

Run `scripts/build.sh` and `scripts/test.sh` for the app and automated tests.
Build the diagnostics with
`cargo build --locked --manifest-path Backend/Cargo.toml --bins`.

1. Close iPhoneMirror and Xcode mirroring. Connect exactly one unlocked iPhone.
2. Verify Camera works, close it, and leave Settings open.
3. `Backend/target/debug/media-status` reads existing sessions; it never starts,
   stops, mounts, or prepares a service, and prints only allowlisted fields.
4. `python3 scripts/check-media-expiry.py` runs a 45-second USB session, closes
   normally, and measures expiry. Add `--crash` to exit without native cleanup.
5. After the tool confirms no media sessions remain, open Camera on the phone
   and verify a changing live preview against a non-sensitive target. If an
   already-open Camera is frozen, close it from the app switcher and reopen it;
   record whether this was needed. Do not infer success from status alone.
6. `scripts/diagnose-connection.sh --seconds 600` exercises the actual coordinator
   and decoder through many timeout intervals. It disables agent access only in
   its own volatile preferences and does not change the installed app's settings.

7. With Use Wi-Fi When Unplugged enabled, mirror over USB, unplug, and confirm
   the app shows Wi-Fi and continues for at least 60 seconds. Disconnect, wait
   30 seconds, and check physical Camera before returning to Settings.
8. Mirror over USB, put the Mac to Sleep, and check Camera after 30 seconds while
   the Mac remains asleep. Close Camera and return to Settings before waking the
   Mac. Confirm mirroring resumes and inspect Connection Diagnostics for retries.

Physical unplug, Wi-Fi fallback, actual Mac sleep/wake, and visible Camera checks
remain distinct from a process-exit test. Check one scenario at a time. A test
must not overlap another mirror client, and Camera should stay closed until the
session and expiry checks have ended.

## Validation record — 15 October 2026

- App build and 143 automated tests pass (63 Rust, 80 Swift), including
  the transport-report regression test added during device validation.
- The connected iPhone negotiated `RTCPTimeoutEnabled=true` and a 20-second
  interval for both audio and video. A short session's streams subsequently
  disappeared without a successful explicit stop request.
- An initial longer test ended at about 35 seconds during overlapping Camera
  investigation. It is not a successful crash or stability test.
- With all test processes ended and device status reporting zero sessions, the
  user confirmed that closing and reopening physical Camera restored its preview.
- Controlled 600-second coordinator/decoder run: one connection, 6,650 decoded
  frames, zero decoder errors/skips, queue overflows, discontinuities or feedback
  failures, and 1,200 successful orientation queries. The maximum 54.967-second
  decoded-output gap occurred on the static screen without reconnecting. Both
  audio/video sessions remained present during the run.
- Normal coordinator shutdown preserved `awaiting expiry` in final diagnostics;
  its status check took 30 ms. Polling first observed zero sessions 20.28 seconds
  after close. The user then confirmed physical Camera worked and returned to Settings.
- A separate 45-second USB probe received 4,463 audio packets through its final
  second, then exited without cleanup. Zero sessions were first observed 19.58
  seconds after process exit. Polling intervals were approximately 1.1–1.4 seconds;
  these figures are observation bounds, not exact device teardown timestamps.
- The user confirmed physical Camera worked after the abrupt-exit test, then
  returned to Settings for the physical cable-removal test.
- Actual development app, USB-only: diagnostics recorded USB removal and session
  closure in the same one-second event bucket. The fresh status check returned
  `unreachable` after 27 ms, correctly leaving remote release unconfirmed. The
  user confirmed physical Camera worked after unplugging and waiting 30 seconds.
  Reconnect attempts were stopped, and the original Wi-Fi continuation preference
  was restored.

- Final rebuilt development app: a new mirror session disconnected normally;
  the idle window visibly displayed the Camera release-delay notice. The app
  was then quit.

- Wi-Fi handoff: USB removal at +31 s, a new decoded picture at +33 s, and
  uninterrupted Wi-Fi mirroring until Disconnect at +113 s (80 seconds live).
  The Wi-Fi session decoded 1,112 frames with no errors, overflows,
  discontinuities or feedback failures; all 160 orientation queries succeeded.
  The shutdown status check took 43 ms and reported awaiting expiry. The user
  confirmed Camera worked after Disconnect and a 30-second wait.
- This test exposed a pre-existing hardcoded USB label in diagnostic reports.
  Reports now use the observed transport, allowlisted to USB/Wi-Fi/unknown;
  missing or unexpected values cannot misreport USB or leak arbitrary text.

- Actual Mac sleep/wake: macOS power logs confirm Software Sleep, a maintenance
  DarkWake, another sleep, and full user wake. The user confirmed Camera worked
  before waking the Mac. App events recorded close at the sleep notification
  (+71 s, status check 157 ms) and new frames two seconds after its wake
  notification (+116 s -> +118 s). The first resumed session stalled at +121 s
  with one queue overflow and automatically retried; a new picture arrived at
  +122 s. That session remained stable for 69 seconds until Disconnect, decoding
  1,550 frames with no errors, overflows or feedback failures and 139 successful
  orientation queries. Cleanup took 34 ms. This validates release during sleep
  and eventual automatic recovery, not seamless wake recovery. Notification
  timestamps are not measurements of the physical sleep duration.

These results cover one iPhone 17 running iOS 27.0. The expiry
strategy also delays normal Disconnect by about 20 seconds; it does not promise
immediate release. An already-frozen Camera may still need closing and reopening.

The installed 0.5.1 application has not been replaced by these development builds.
