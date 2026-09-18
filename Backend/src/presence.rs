//! USB presence notifications are independent of media and remain alive during retry backoff.
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

#[derive(Default)]
struct PresenceState {
    ids: BTreeSet<u32>,
}
impl PresenceState {
    fn apply(&mut self, target: &str, event: UsbmuxdListenEvent) -> Option<i32> {
        let before = !self.ids.is_empty();
        match event {
            UsbmuxdListenEvent::Connected(d)
                if d.udid == target && d.connection_type == Connection::Usb =>
            {
                self.ids.insert(d.device_id);
            }
            UsbmuxdListenEvent::Disconnected(id) => {
                self.ids.remove(&id);
            }
            _ => {}
        }
        let after = !self.ids.is_empty();
        (before != after).then_some(if after { 1 } else { 2 })
    }
}
async fn observe(udid: &str, events: &mpsc::SyncSender<i32>) -> crate::Result<()> {
    let mut mux = bounded("USB monitor", UsbmuxdConnection::default()).await?;
    // Subscribe first, then take a snapshot on another socket so no detach is lost between them.
    let mut stream = bounded("USB notifications", mux.listen()).await?;
    let mut snapshot = bounded("USB snapshot", UsbmuxdConnection::default()).await?;
    let devices = bounded("USB devices", snapshot.get_devices()).await?;
    let mut state = PresenceState::default();
    for device in devices {
        state.apply(udid, UsbmuxdListenEvent::Connected(device));
    }
    events
        .try_send(if state.ids.is_empty() { 2 } else { 1 })
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
pub unsafe extern "C" fn pm_presence_start(udid: *const c_char) -> *mut PMPresence {
    if udid.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(udid) = (unsafe { CStr::from_ptr(udid) }).to_str() else {
        return std::ptr::null_mut();
    };
    let udid = udid.to_owned();
    let (tx, rx) = mpsc::sync_channel(64);
    let (cancel, mut cancelled_rx) = watch::channel(false);
    let worker = thread::spawn(move || {
        let Ok(rt) = runtime() else {
            let _ = tx.try_send(3);
            return;
        };
        rt.block_on(async {
            loop {
                tokio::select! {
                    biased;
                    _ = cancelled(&mut cancelled_rx) => break,
                    _ = observe(&udid, &tx) => { let _ = tx.try_send(3); }
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
/// Nonblocking; 0 = no event, 1 = USB attached, 2 = USB absent, 3 = monitor unavailable.
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
