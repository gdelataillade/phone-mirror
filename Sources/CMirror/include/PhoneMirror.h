#ifndef PHONE_MIRROR_H
#define PHONE_MIRROR_H
#include <stdint.h>
#include <stddef.h>
typedef struct PMHandle PMHandle;
typedef struct PMEvent PMEvent;
typedef struct PMPresence PMPresence;
PMPresence *pm_presence_start(const char *udid);
// Nonblocking: 0 no event, 1 USB attached, 2 USB absent, 3 monitoring unavailable.
int32_t pm_presence_poll(PMPresence *handle);
void pm_presence_close(PMPresence *handle);
// Returned text is UTF-8 JSON. Caller frees it with pm_string_free.
char *pm_devices(void);
void pm_string_free(char *text);
PMHandle *pm_start(const char *udid);
// Numeric-only telemetry JSON; free with pm_string_free. No identity or payloads.
char *pm_health(PMHandle *handle);
// One consumer only. Events own their bytes until pm_event_free. No callbacks.
PMEvent *pm_poll(PMHandle *handle, uint32_t timeout_ms);
uint32_t pm_event_kind(const PMEvent *event); // 1 status, 2 frame, 3 error, 4 stopped, 5 rotation acknowledged (JSON), 6 rotation error
const uint8_t *pm_event_data(const PMEvent *event, uint32_t part, size_t *length);
uint32_t pm_event_value(const PMEvent *event, uint32_t field); // width,height,sync,timestamp,orientation
void pm_event_free(PMEvent *event);
// 1 touch down/move, 2 touch up, 3 key down, 4 key up, 5 Home, 6 release all,
// 7 request keyframe, 8 App Switcher, 9 rotate right, 10 rotate left.
// Coordinates normalized 0…65535; key is USB HID usage.
int32_t pm_command(PMHandle *handle, uint32_t kind, uint32_t a, uint32_t b);
// Explicit one-shot UTF-8 paste. Maximum 64 KiB. Replaces the device clipboard.
int32_t pm_paste(PMHandle *handle, const uint8_t *text, size_t length);
void pm_cancel(PMHandle *handle);
// No other call may use handle once close starts. Joins all work; may block.
void pm_close(PMHandle *handle);
#endif
