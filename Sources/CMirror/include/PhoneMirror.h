#ifndef PHONE_MIRROR_H
#define PHONE_MIRROR_H
#include <stdint.h>
#include <stddef.h>
typedef struct PMHandle PMHandle;
typedef struct PMEvent PMEvent;
typedef struct PMPresence PMPresence;
// transports: 1 USB only, 3 USB or Wi-Fi (usbmuxd's network connection).
PMPresence *pm_presence_start(const char *udid, uint32_t transports);
// Nonblocking: 0 no event, 1 on USB, 2 absent, 3 monitoring unavailable,
// 4 reachable over Wi-Fi only (only when Wi-Fi was allowed).
int32_t pm_presence_poll(PMPresence *handle);
void pm_presence_close(PMPresence *handle);
// Returned text is UTF-8 JSON. Caller frees it with pm_string_free.
char *pm_devices(void);
void pm_string_free(char *text);
// Setup prerequisites for a USB iPhone as JSON: ddiOnMac, connected, trusted,
// developerMode, ddiMounted, ddiVersion, developerServices, wifiConnections, detail.
// Uses USB, or Wi-Fi when unplugged. Blocks; never modifies
// the phone. Opens its own tunnel: don't call it during a mirroring session.
char *pm_prepare_status(const char *udid);
// 1 reveal the Developer Mode setting, 2 mount the developer disk image from Xcode's copy
// on this Mac, 3 turn on the phone's Wi-Fi connections. Blocks.
// JSON {"ok":true[,"mounted":bool]} or {"error":"..."}.
char *pm_prepare(const char *udid, uint32_t action);
// transports: 1 USB only, 3 USB preferred with Wi-Fi fallback. Event kind 8 reports the
// transport used ("usb" or "wifi").
PMHandle *pm_start(const char *udid, uint32_t transports);
// Numeric-only telemetry JSON; free with pm_string_free. No identity or payloads.
char *pm_health(PMHandle *handle);
// One consumer only. Events own their bytes until pm_event_free. No callbacks.
PMEvent *pm_poll(PMHandle *handle, uint32_t timeout_ms);
// Independent queue from pm_poll: audio decode must never wait on video decode, or the reverse.
// One consumer only.
PMEvent *pm_poll_audio(PMHandle *handle, uint32_t timeout_ms);
uint32_t pm_event_kind(const PMEvent *event); // 1 status, 2 frame, 3 error, 4 stopped, 5 rotation acknowledged (JSON), 6 rotation error, 7 audio frame (from pm_poll_audio)
const uint8_t *pm_event_data(const PMEvent *event, uint32_t part, size_t *length);
uint32_t pm_event_value(const PMEvent *event, uint32_t field); // width,height,sync,timestamp,orientation; for kind 7: RTP timestamp only
void pm_event_free(PMEvent *event);
// 1 touch down/move, 2 touch up, 3 key down, 4 key up, 5 Home, 6 release all,
// 7 request keyframe, 8 App Switcher, 9 rotate right, 10 rotate left,
// 11 Spotlight, 12 Control Center, 13 hardware button (a: 1 lock, 2 volume up,
// 3 volume down; other values are ignored).
// Coordinates normalized 0…65535; key is USB HID usage.
int32_t pm_command(PMHandle *handle, uint32_t kind, uint32_t a, uint32_t b);
// Explicit one-shot UTF-8 paste. Maximum 64 KiB. Replaces the device clipboard.
int32_t pm_paste(PMHandle *handle, const uint8_t *text, size_t length);
// Explicit one-shot image paste. Maximum 15 MiB (provisional; see VALIDATION.md).
// format: 0 PNG, 1 JPEG. Replaces the device clipboard.
int32_t pm_paste_image(
    PMHandle *handle, const uint8_t *bytes, size_t length, uint32_t format);
// App control on a separate device connection from input.
// request is UTF-8 JSON: {"op":"list","system":bool} | {"op":"launch","bundleID":…,
// "restart":bool} | {"op":"terminate","bundleID":…}. Nonblocking; null only for a
// null handle. The call does not borrow the handle once returned.
typedef struct PMAppCall PMAppCall;
PMAppCall *pm_app_start(PMHandle *handle, const char *request);
// Blocks up to timeout_ms (max 30000) and frees call. Returns JSON
// {"status":200,"result":{...}} or {"status":N,"error":"..."}; free with pm_string_free.
char *pm_app_wait(PMAppCall *call, uint32_t timeout_ms);
void pm_cancel(PMHandle *handle);
// No other call may use handle once close starts. Joins all work; may block.
void pm_close(PMHandle *handle);
#endif
