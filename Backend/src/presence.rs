//! Presence notifications (USB, and optionally usbmuxd's Wi-Fi entries) are independent of
//! media and remain alive during retry backoff.
use crate::{bounded, cancelled, runtime};
use idevice::usbmuxd::{Connection, UsbmuxdConnection, UsbmuxdListenEvent};
use std::{
    collections::BTreeSet,
    ffi::{CStr, c_char},
    sync::{Mutex, mpsc},
    thread,
    time::Duration,
};
use tokio::sync::watch;

pub struct PMPresence {
    events: Mutex<mpsc::Receiver<i32>>,
    cancel: watch::Sender<bool>,
    worker: Option<thread::JoinHandle<()>>,
}

/// Values pm_presence_poll delivers.
const ON_USB: i32 = 1;
const ABSENT: i32 = 2;
const UNAVAILABLE: i32 = 3;
const WIFI_ONLY: i32 = 4;

#[derive(Default)]
struct PresenceState {
    usb: BTreeSet<u32>,
    wifi: BTreeSet<u32>,
    allow_wifi: bool,
}
impl PresenceState {
    fn reach(&self) -> i32 {
        if !self.usb.is_empty() {
            ON_USB
        } else if !self.wifi.is_empty() {
            WIFI_ONLY
        } else {
            ABSENT
        }
    }
    /// The new reach when this event changed it.
    fn apply(&mut self, target: &str, event: UsbmuxdListenEvent) -> Option<i32> {
        let before = self.reach();
        match event {
            UsbmuxdListenEvent::Connected(d) if d.udid == target => match d.connection_type {
                Connection::Usb => {
                    self.usb.insert(d.device_id);
                }
                Connection::Network(_) if self.allow_wifi => {
                    self.wifi.insert(d.device_id);
                }
                _ => {}
            },
            UsbmuxdListenEvent::Disconnected(id) => {
                self.usb.remove(&id);
                self.wifi.remove(&id);
            }
            _ => {}
        }
        let after = self.reach();
        (before != after).then_some(after)
    }
}
async fn observe(
    udid: &str,
    allow_wifi: bool,
    events: &mpsc::SyncSender<i32>,
) -> crate::Result<()> {
    let mut mux = bounded("USB monitor", UsbmuxdConnection::default()).await?;
    // Subscribe first, then take a snapshot on another socket so no detach is lost between them.
    let mut stream = bounded("USB notifications", mux.listen()).await?;
    let mut snapshot = bounded("USB snapshot", UsbmuxdConnection::default()).await?;
    let devices = bounded("USB devices", snapshot.get_devices()).await?;
    let mut state = PresenceState {
        allow_wifi,
        ..Default::default()
    };
    for device in devices {
        state.apply(udid, UsbmuxdListenEvent::Connected(device));
    }
    events
        .try_send(state.reach())
        .map_err(|_| "Monitor closed")?;
    while let Some(event) = std::future::poll_fn(|cx| stream.as_mut().poll_next(cx)).await {
        let event = event.map_err(|e| e.to_string())?;
        if let Some(value) = state.apply(udid, event) {
            events.try_send(value).map_err(|_| "Monitor closed")?;
        }
    }
    Err("USB notifications ended".into())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_presence_start(
    udid: *const c_char,
    transports: u32,
) -> *mut PMPresence {
    if udid.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(udid) = (unsafe { CStr::from_ptr(udid) }).to_str() else {
        return std::ptr::null_mut();
    };
    let udid = udid.to_owned();
    let allow_wifi = transports & crate::TRANSPORT_WIFI != 0;
    let (tx, rx) = mpsc::sync_channel(64);
    let (cancel, mut cancelled_rx) = watch::channel(false);
    let worker = thread::spawn(move || {
        let Ok(rt) = runtime() else {
            let _ = tx.try_send(UNAVAILABLE);
            return;
        };
        rt.block_on(async {
            loop {
                tokio::select! {
                    biased;
                    _ = cancelled(&mut cancelled_rx) => break,
                    _ = observe(&udid, allow_wifi, &tx) => { let _ = tx.try_send(UNAVAILABLE); }
                }
                tokio::select! {
                    _ = cancelled(&mut cancelled_rx) => break,
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {}
                }
            }
        });
    });
    Box::into_raw(Box::new(PMPresence {
        events: Mutex::new(rx),
        cancel,
        worker: Some(worker),
    }))
}
/// Nonblocking; 0 = no event, 1 = on USB, 2 = absent, 3 = monitor unavailable,
/// 4 = reachable over Wi-Fi only (reported only when Wi-Fi was allowed).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_presence_poll(handle: *mut PMPresence) -> i32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    handle
        .events
        .lock()
        .ok()
        .and_then(|rx| rx.try_recv().ok())
        .unwrap_or(0)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_presence_close(handle: *mut PMPresence) {
    if handle.is_null() {
        return;
    }
    let mut handle = unsafe { Box::from_raw(handle) };
    let _ = handle.cancel.send(true);
    if let Some(worker) = handle.worker.take() {
        let _ = worker.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use idevice::usbmuxd::UsbmuxdDevice;
    fn attach(id: u32, name: &str, connection_type: Connection) -> UsbmuxdListenEvent {
        UsbmuxdListenEvent::Connected(UsbmuxdDevice {
            device_id: id,
            udid: name.into(),
            connection_type,
        })
    }
    #[test]
    fn wifi_counts_only_when_allowed_and_usb_takes_precedence() {
        let wifi = || Connection::Network("192.0.2.1".parse().unwrap());
        let mut state = PresenceState {
            allow_wifi: true,
            ..Default::default()
        };
        assert_eq!(state.apply("a", attach(5, "a", wifi())), Some(WIFI_ONLY));
        assert_eq!(
            state.apply("a", attach(6, "a", Connection::Usb)),
            Some(ON_USB)
        );
        // Unplugging falls back to Wi-Fi rather than absent.
        assert_eq!(
            state.apply("a", UsbmuxdListenEvent::Disconnected(6)),
            Some(WIFI_ONLY)
        );
        assert_eq!(
            state.apply("a", UsbmuxdListenEvent::Disconnected(5)),
            Some(ABSENT)
        );
    }
    #[test]
    fn filters_other_devices_wifi_and_duplicate_initial_notifications() {
        let mut state = PresenceState::default();
        assert_eq!(state.apply("a", attach(1, "b", Connection::Usb)), None);
        assert_eq!(
            state.apply(
                "a",
                attach(2, "a", Connection::Network("127.0.0.1".parse().unwrap()))
            ),
            None
        );
        assert_eq!(state.apply("a", attach(3, "a", Connection::Usb)), Some(1));
        assert_eq!(state.apply("a", attach(3, "a", Connection::Usb)), None);
        assert_eq!(state.apply("a", UsbmuxdListenEvent::Disconnected(1)), None);
        assert_eq!(
            state.apply("a", UsbmuxdListenEvent::Disconnected(3)),
            Some(2)
        );
        assert_eq!(state.apply("a", attach(4, "a", Connection::Usb)), Some(1));
    }
}
