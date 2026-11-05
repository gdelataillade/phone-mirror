Improves window sizing, idle performance, audio reliability and connection security.

- Keep the floating title bar proportional to the phone, with window resize edges close to the visible frame and standard macOS controls.
- Avoid unnecessary redraws while disconnected, reducing idle CPU use in local testing.
- Improve audio startup recovery, mute/resume and volume handling; bound queued audio to avoid accumulating delay.
- Correct recovered-video health tracking and retain clearer connection failure diagnostics across reconnects.
- Verify paired-device certificates and TLS signatures, use HTTPS for personalization and reject malformed or oversized HTTP responses.
- Reject cancelled or stale automation responses after connection or access changes.
- Verify published update assets before advertising them through Sparkle.

Known limitation: intermittent Wi-Fi reconnects can still occur. Their causes are unconfirmed and they are accepted as non-blocking for this release; uninterrupted long-session stability is not claimed.

Requires macOS 27.0 or later. Camera may still need about 20 seconds to become available after disconnecting, as in 0.5.2.
