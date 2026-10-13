//! FIFO completion marker. It acknowledges transport dispatch, never UI success.
use crate::{Command, PMHandle};
use std::{
    sync::mpsc,
    time::{SystemTime, UNIX_EPOCH},
};

pub struct PMDispatchCall(mpsc::Receiver<f64>);

pub(crate) fn complete(reply: mpsc::SyncSender<f64>) {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    let _ = reply.try_send(timestamp);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_dispatch_start(handle: *mut PMHandle) -> *mut PMDispatchCall {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return std::ptr::null_mut();
    };
    if *h.cancel.borrow() {
        return std::ptr::null_mut();
    }
    let (tx, rx) = mpsc::sync_channel(1);
    if h.commands.try_send(Command::Dispatch(tx)).is_err() {
        let _ = h.cancel.send(true);
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(PMDispatchCall(rx)))
}

/// 0 pending, 1 dispatched (writes host Unix seconds), -1 failed/closed.
/// The caller polls at most until the first terminal result, then frees the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_dispatch_poll(call: *mut PMDispatchCall, timestamp: *mut f64) -> i32 {
    let Some(call) = (unsafe { call.as_ref() }) else {
        return -1;
    };
    if timestamp.is_null() {
        return -1;
    }
    match call.0.try_recv() {
        Ok(value) => {
            unsafe {
                *timestamp = value;
            }
            1
        }
        Err(mpsc::TryRecvError::Empty) => 0,
        Err(mpsc::TryRecvError::Disconnected) => -1,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_dispatch_free(call: *mut PMDispatchCall) {
    if !call.is_null() {
        drop(unsafe { Box::from_raw(call) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn handle() -> (
        PMHandle,
        tokio::sync::mpsc::Receiver<Command>,
        tokio::sync::watch::Receiver<bool>,
    ) {
        let (commands, input) = tokio::sync::mpsc::channel(1);
        let (apps, _) = tokio::sync::mpsc::channel(1);
        let (cancel, stop) = tokio::sync::watch::channel(false);
        (
            PMHandle {
                health: Default::default(),
                events: std::sync::Mutex::new(mpsc::channel().1),
                audio_events: std::sync::Mutex::new(mpsc::channel().1),
                commands,
                apps,
                cancel,
                worker: None,
            },
            input,
            stop,
        )
    }
    #[test]
    fn marker_overflow_cancels_session_instead_of_claiming_dispatch() {
        let (mut handle, _input, stop) = handle();
        handle.commands.try_send(Command::Input(2, 0, 0)).unwrap();
        unsafe {
            assert!(pm_dispatch_start(&mut handle).is_null());
        }
        assert!(*stop.borrow());
        unsafe {
            assert!(pm_dispatch_start(&mut handle).is_null());
        }
    }
    #[test]
    fn queued_marker_survives_handle_drop_and_reports_closed_input() {
        let (mut handle, input, _stop) = handle();
        let call = unsafe { pm_dispatch_start(&mut handle) };
        assert!(!call.is_null());
        drop(handle);
        let mut timestamp = 0.0;
        unsafe {
            assert_eq!(pm_dispatch_poll(call, &mut timestamp), 0);
        }
        drop(input);
        unsafe {
            assert_eq!(pm_dispatch_poll(call, &mut timestamp), -1);
            pm_dispatch_free(call);
            assert_eq!(pm_dispatch_poll(std::ptr::null_mut(), &mut timestamp), -1);
            pm_dispatch_free(std::ptr::null_mut());
        }
    }
    #[test]
    fn marker_is_pending_until_processed_and_failure_is_not_success() {
        let (tx, rx) = mpsc::sync_channel(1);
        let call = Box::into_raw(Box::new(PMDispatchCall(rx)));
        let mut timestamp = 0.0;
        unsafe {
            assert_eq!(pm_dispatch_poll(call, &mut timestamp), 0);
            complete(tx);
            assert_eq!(pm_dispatch_poll(call, &mut timestamp), 1);
            assert!(timestamp > 1_700_000_000.0);
            pm_dispatch_free(call);
        }
        let (tx, rx) = mpsc::sync_channel(1);
        let call = Box::into_raw(Box::new(PMDispatchCall(rx)));
        drop(tx); // An input failure drops queued markers without acknowledging them.
        unsafe {
            assert_eq!(pm_dispatch_poll(call, &mut timestamp), -1);
            pm_dispatch_free(call);
        }
    }
    #[tokio::test]
    async fn marker_preserves_fifo_and_abandoned_waiter_does_not_block_input() {
        let (queue, mut input) = tokio::sync::mpsc::channel(4);
        let (tx, rx) = mpsc::sync_channel(1);
        queue.send(Command::Input(2, 0, 0)).await.unwrap();
        queue.send(Command::Dispatch(tx)).await.unwrap();
        assert!(matches!(input.recv().await, Some(Command::Input(2, 0, 0))));
        assert!(matches!(rx.try_recv(), Err(mpsc::TryRecvError::Empty)));
        drop(rx);
        if let Some(Command::Dispatch(reply)) = input.recv().await {
            complete(reply);
        }
        queue.send(Command::Input(6, 0, 0)).await.unwrap();
        assert!(matches!(input.recv().await, Some(Command::Input(6, 0, 0))));
    }
}
