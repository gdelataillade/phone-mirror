# Native protocol dependency

`idevice/` is the MIT-licensed idevice crate from commit
`d32c8189c51c2789496b0768039419c3705498c3` of https://github.com/jkcoxson/idevice.
Its Cargo manifest and source are vendored so the local changes are reproducible.

Four selective patches come from the MIT-licensed device-hub-ios project,
commit `1fcdfb0a6799b62f05625d0cbb359bec57256b94`:
https://github.com/JaviSoto/device-hub-ios

- HEVC marker-closed access units, bounded packet reordering, exact Apple trailer removal,
  parameter-set validation, conformance dimensions and keyframe recovery.
- Negotiated HEVC payload/SSRC validation and bounded answer decompression.
- Protobuf parser integrity checks used by that answer parser.
- Read-only orientation query.

These upstream changes are recorded in `media-reliability.patch`. Both licenses are retained.

Before publishing this repository, `remote_pairing/opack.rs` was replaced with
the version from idevice commit `3d46f2c5087c429ecb9b93a3c84f903461743ec4`, whose
[crate manifest declares MIT](https://github.com/jkcoxson/idevice/blob/3d46f2c5087c429ecb9b93a3c84f903461743ec4/idevice/Cargo.toml).
The later module included a captured device pairing fixture and attributed its
back-reference additions to a project with different licensing terms. Retaining
the earlier module removes both from this distribution. Its two codec tests are
run by `scripts/test.sh`. PhoneMirror does not enable the `remote_pairing` feature;
its USB display/input path is unaffected. That optional module does not include
the later back-reference support. The peer-device test uses an all-zero synthetic
device identifier.

Our additional change to `display_stream/client.rs` adds `stop_owned_session(UUID)` using
the session-specific XPC UUID field. The application never calls `stop_media_stream()`,
whose upstream implementation uses `stopAll=true`.

Our additional change to `display_stream/negotiation.rs` disables the video settings'
long-term reference mode (field 7). The assembler requires ordinary HEVC
random-access frames after loss. On the tested phone, keyframe requests did not
restore a deliberately overflowed stream; the app recovers by starting a new owned
session. The negotiation change alone is not a proven fix for packet loss.

The initial offer retains upstream's captured compatibility profile strings. They describe
the negotiation profile; they are not telemetry or assertions about this Mac's identity.
Media/audio uses one owned UUID. Audio is drained but not played in the first preview.

The app uses the existing macOS usbmuxd trust relationship. It does not read protected
pairing files, install a root daemon, embed Apple private frameworks, or install a runner.
