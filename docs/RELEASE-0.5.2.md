Fixes prolonged iPhone Camera unavailability after mirroring ends or the USB cable is unplugged.

- Abandoned audio/video streams now expire after about 20 seconds instead of potentially remaining for an hour.
- Active sessions send periodic keepalives, including during silence and static screens.
- Disconnect displays the possible Camera release delay; diagnostics distinguish confirmed absence from pending or unconfirmed cleanup and report the actual transport.

Camera release is not immediate: allow about 20 seconds after mirroring stops. If Camera was already frozen, close and reopen it. Unplugging with Wi-Fi continuation enabled keeps mirroring active; use Disconnect to end that session.

Validation: 143 automated tests; 10-minute device soak; physical Camera checks after normal shutdown, abrupt exit, USB removal, and Wi-Fi Disconnect. Camera also worked during actual Mac sleep. Mirroring recovered after wake with one additional automatic reconnect, followed by 69 seconds of stable operation. Tested on iPhone 17 / iOS 27.0; other devices and OS versions remain unverified.
