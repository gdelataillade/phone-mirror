//! Native USB/CoreDevice backend. The C boundary owns all allocations explicitly.
//! No listening network ports, companion app, XCTest runner, or global stream stop.
use idevice::core_device::display_stream::{
    hevc::{HevcAccessUnitAssembler, HevcDepacketizerEvent},
    negotiation::parse_screen_video_answer,
};
use idevice::{
    IdeviceService, ReadWrite, RsdService,
    core_device::*,
    core_device_proxy::CoreDeviceProxy,
    lockdown::LockdownClient,
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use std::{
    collections::BTreeSet,
    ffi::{CStr, CString, c_char},
    sync::{Arc, Mutex, mpsc},
    thread,
    time::Duration,
};
use tokio::sync::{mpsc as async_mpsc, watch};
mod health;
mod orientation;
mod presence;
pub use presence::*;

type Result<T> = std::result::Result<T, String>;
type Display = DisplayServiceClient<Box<dyn ReadWrite>>;

fn runtime() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| e.to_string())
}
async fn bounded<T, E: std::fmt::Display>(
    label: &str,
    f: impl std::future::Future<Output = std::result::Result<T, E>>,
) -> Result<T> {
    tokio::time::timeout(Duration::from_secs(12), f)
        .await
        .map_err(|_| format!("{label} timed out. Unlock the iPhone and check its USB connection."))?
        .map_err(|e| format!("{label}: {e}"))
}

pub async fn devices() -> Result<serde_json::Value> {
    let mut mux = bounded("USB discovery", UsbmuxdConnection::default()).await?;
    let mut found = Vec::new();
    for device in bounded("Device list", mux.get_devices())
        .await?
        .into_iter()
        .filter(|d| d.connection_type == Connection::Usb)
    {
        let provider = device.to_provider(UsbmuxdAddr::default(), "iPhoneMirror");
        let mut name = "iPhone".to_string();
        let mut version = String::new();
        if let Ok(mut lockdown) =
            bounded("Device identity", LockdownClient::connect(&provider)).await
        {
            if let Ok(v) =
                bounded("Device name", lockdown.get_value(Some("DeviceName"), None)).await
            {
                name = v.as_string().unwrap_or("iPhone").into();
            }
            if let Ok(v) = bounded(
                "Device version",
                lockdown.get_value(Some("ProductVersion"), None),
            )
            .await
            {
                version = v.as_string().unwrap_or("").into();
            }
        }
        found.push(
            serde_json::json!({"id":device.udid,"name":name,"version":version,"transport":"USB"}),
        );
    }
    Ok(serde_json::json!({"devices":found}))
}

pub struct PMEvent {
    kind: u32,
    values: [u32; 5],
    parts: [Vec<u8>; 4],
}
impl PMEvent {
    fn message(kind: u32, text: impl Into<String>) -> Self {
        Self {
            kind,
            values: [0; 5],
            parts: [text.into().into_bytes(), vec![], vec![], vec![]],
        }
    }
}
pub struct PMHandle {
    health: health::SharedHealth,
    events: Mutex<mpsc::Receiver<PMEvent>>,
    audio_events: Mutex<mpsc::Receiver<PMEvent>>,
    commands: async_mpsc::Sender<Command>,
    cancel: watch::Sender<bool>,
    worker: Option<thread::JoinHandle<()>>,
}
enum Command {
    Input(u32, u32, u32),
    Paste(String),
    // The UTI to set it under: UTI_PNG or UTI_JPEG, chosen by the caller.
    PasteImage(Vec<u8>, &'static str),
}
fn status(tx: &mpsc::SyncSender<PMEvent>, message: &str) {
    let _ = tx.try_send(PMEvent::message(1, message));
}

#[unsafe(no_mangle)]
pub extern "C" fn pm_devices() -> *mut c_char {
    let value = match runtime().and_then(|rt| rt.block_on(devices())) {
        Ok(v) => v,
        Err(e) => serde_json::json!({"devices":[],"error":e}),
    };
    CString::new(value.to_string())
        .unwrap_or_default()
        .into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_start(udid: *const c_char) -> *mut PMHandle {
    if udid.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(udid) = unsafe { CStr::from_ptr(udid) }.to_str() else {
        return std::ptr::null_mut();
    };
    let udid = udid.to_owned();
    let (tx, rx) = mpsc::sync_channel(16);
    // Separate from the video/status channel so a stalled video decode on the
    // consumer side can never starve audio delivery, or the reverse.
    let (audio_tx, audio_rx) = mpsc::sync_channel(48);
    let (command_tx, command_rx) = async_mpsc::channel(64);
    let (cancel_tx, cancel_rx) = watch::channel(false);
    let health = Arc::new(Mutex::new(health::Health::default()));
    let worker_health = health.clone();
    let worker = thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            runtime()?.block_on(run(
                &udid,
                &tx,
                &audio_tx,
                command_rx,
                cancel_rx,
                &worker_health,
            ))
        }))
        .unwrap_or_else(|_| {
            Err("The native session stopped unexpectedly. Reconnect to try again.".into())
        });
        // Terminal delivery is bounded and cancellable by dropping the receiver in pm_close.
        if let Err(e) = result {
            let _ = tx.send(PMEvent::message(3, e));
        }
        let _ = tx.send(PMEvent::message(4, "Disconnected"));
        let _ = audio_tx.send(PMEvent::message(4, "Disconnected"));
    });
    Box::into_raw(Box::new(PMHandle {
        health,
        events: Mutex::new(rx),
        audio_events: Mutex::new(audio_rx),
        commands: command_tx,
        cancel: cancel_tx,
        worker: Some(worker),
    }))
}
/// Numeric telemetry only; free the returned JSON using pm_string_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_health(handle: *mut PMHandle) -> *mut c_char {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return std::ptr::null_mut();
    };
    let Ok(health) = h.health.lock() else {
        return std::ptr::null_mut();
    };
    CString::new(health.json()).unwrap_or_default().into_raw()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_poll(handle: *mut PMHandle, timeout_ms: u32) -> *mut PMEvent {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return std::ptr::null_mut();
    };
    match h.events.lock().ok().and_then(|rx| {
        rx.recv_timeout(Duration::from_millis(timeout_ms.min(1000) as u64))
            .ok()
    }) {
        Some(event) => Box::into_raw(Box::new(event)),
        None => std::ptr::null_mut(),
    }
}
/// Independent from pm_poll: audio decode must never wait on video decode, or the reverse.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_poll_audio(handle: *mut PMHandle, timeout_ms: u32) -> *mut PMEvent {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return std::ptr::null_mut();
    };
    match h.audio_events.lock().ok().and_then(|rx| {
        rx.recv_timeout(Duration::from_millis(timeout_ms.min(1000) as u64))
            .ok()
    }) {
        Some(event) => Box::into_raw(Box::new(event)),
        None => std::ptr::null_mut(),
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_event_kind(e: *const PMEvent) -> u32 {
    unsafe { e.as_ref() }.map(|e| e.kind).unwrap_or(0)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_event_value(e: *const PMEvent, field: u32) -> u32 {
    unsafe { e.as_ref() }
        .and_then(|e| e.values.get(field as usize))
        .copied()
        .unwrap_or(0)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_event_data(e: *const PMEvent, part: u32, len: *mut usize) -> *const u8 {
    if len.is_null() {
        return std::ptr::null();
    }
    unsafe {
        *len = 0;
    }
    let Some(data) = (unsafe { e.as_ref() }).and_then(|e| e.parts.get(part as usize)) else {
        return std::ptr::null();
    };
    unsafe {
        *len = data.len();
    }
    data.as_ptr()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_event_free(e: *mut PMEvent) {
    if !e.is_null() {
        drop(unsafe { Box::from_raw(e) });
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_command(handle: *mut PMHandle, kind: u32, a: u32, b: u32) -> i32 {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if *h.cancel.borrow() {
        return 0;
    }
    if h.commands.try_send(Command::Input(kind, a, b)).is_ok() {
        1
    } else {
        // Never drop an input edge and leave a key or touch held on the device.
        let _ = h.cancel.send(true);
        0
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_paste(handle: *mut PMHandle, text: *const u8, length: usize) -> i32 {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if text.is_null() || length == 0 || length > 65536 || *h.cancel.borrow() {
        return 0;
    }
    let Ok(text) = std::str::from_utf8(unsafe { std::slice::from_raw_parts(text, length) }) else {
        return 0;
    };
    if h.commands.try_send(Command::Paste(text.into())).is_ok() {
        1
    } else {
        let _ = h.cancel.send(true);
        0
    }
}
// A generous outer safety bound, not the real practical limit: a real 1.3MB PNG
// photo reliably failed to paste at all (confirmed live, with the transport layer
// itself ruled out — see VALIDATION.md), while 420KB worked. The Swift side
// re-encodes to JPEG above a much lower threshold specifically to stay under
// whatever that real ceiling is; this just guards against truly excessive input.
const MAX_PASTE_IMAGE_BYTES: usize = 15 * 1024 * 1024;
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_paste_image(
    handle: *mut PMHandle,
    bytes: *const u8,
    length: usize,
    format: u32, // 0 = PNG, 1 = JPEG
) -> i32 {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if bytes.is_null() || length == 0 || length > MAX_PASTE_IMAGE_BYTES || *h.cancel.borrow() {
        return 0;
    }
    let uti = if format == 1 { UTI_JPEG } else { UTI_PNG };
    let data = unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec();
    if h.commands.try_send(Command::PasteImage(data, uti)).is_ok() {
        1
    } else {
        let _ = h.cancel.send(true);
        0
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_cancel(handle: *mut PMHandle) {
    if let Some(h) = unsafe { handle.as_ref() } {
        let _ = h.cancel.send(true);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pm_close(handle: *mut PMHandle) {
    if handle.is_null() {
        return;
    }
    let mut h = unsafe { Box::from_raw(handle) };
    let _ = h.cancel.send(true);
    let worker = h.worker.take();
    drop(h); // Unblock a terminal event producer before joining it.
    if let Some(worker) = worker {
        let _ = worker.join();
    }
}

async fn cancelled(rx: &mut watch::Receiver<bool>) {
    if *rx.borrow() {
        return;
    }
    let _ = rx.changed().await;
}
async fn run(
    udid: &str,
    tx: &mpsc::SyncSender<PMEvent>,
    audio_tx: &mpsc::SyncSender<PMEvent>,
    commands: async_mpsc::Receiver<Command>,
    mut cancel: watch::Receiver<bool>,
    health: &health::SharedHealth,
) -> Result<()> {
    health::stage(health, 1);
    status(tx, "Opening USB connection…");
    let connection = async {
        let mut mux = bounded("USB connection", UsbmuxdConnection::default()).await?;
        let device = bounded("Selected iPhone", mux.get_devices())
            .await?
            .into_iter()
            .find(|d| d.udid == udid && d.connection_type == Connection::Usb)
            .ok_or("Connect this iPhone by USB and unlock it.")?;
        let provider = device.to_provider(UsbmuxdAddr::default(), "iPhoneMirror");
        status(tx, "Opening developer services…");
        health::stage(health, 2);
        let proxy = bounded(
            "Developer services (prepare the device in Xcode first)",
            CoreDeviceProxy::connect(&provider),
        )
        .await?;
        let port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy
            .create_software_tunnel()
            .map_err(|e| format!("USB tunnel: {e}"))?
            .to_async_handle();
        health::stage(health, 3);
        let stream = bounded("Remote service discovery", adapter.connect(port)).await?;
        let mut rsd = bounded("Remote services", RsdHandshake::new(stream)).await?;
        let display = bounded(
            "Display service",
            DisplayServiceClient::connect_rsd(&mut adapter, &mut rsd),
        )
        .await?;
        Ok::<_, String>((adapter, rsd, display))
    };
    let (mut adapter, mut rsd, mut display) = tokio::select! {
        result = connection => result?, _ = cancelled(&mut cancel) => return Ok(()),
    };
    let session_id = uuid::Uuid::new_v4();
    let result = stream(
        &mut adapter,
        &mut rsd,
        &mut display,
        session_id,
        tx,
        audio_tx,
        commands,
        cancel.clone(),
        health,
    )
    .await;
    // Cleanup even when setup was cancelled after the audio half started.
    status(tx, "Closing session…");
    let _ = tokio::time::timeout(
        Duration::from_millis(300),
        display.stop_owned_session(session_id),
    )
    .await;
    result
}

fn find_data<'a>(v: &'a plist::Value, key: &str, depth: usize) -> Option<&'a [u8]> {
    if depth > 16 {
        return None;
    }
    match v {
        plist::Value::Dictionary(d) => d
            .get(key)
            .and_then(|v| v.as_data())
            .or_else(|| d.values().find_map(|v| find_data(v, key, depth + 1))),
        plist::Value::Array(a) => a.iter().find_map(|v| find_data(v, key, depth + 1)),
        _ => None,
    }
}
fn find_int(v: &plist::Value, key: &str, depth: usize) -> Option<i64> {
    if depth > 16 {
        return None;
    }
    match v {
        plist::Value::Dictionary(d) => d
            .get(key)
            .and_then(plist::Value::as_signed_integer)
            .or_else(|| d.values().find_map(|v| find_int(v, key, depth + 1))),
        plist::Value::Array(a) => a.iter().find_map(|v| find_int(v, key, depth + 1)),
        _ => None,
    }
}
async fn stream(
    adapter: &mut AdapterHandle,
    rsd: &mut RsdHandshake,
    display: &mut Display,
    session_id: uuid::Uuid,
    tx: &mpsc::SyncSender<PMEvent>,
    audio_tx: &mpsc::SyncSender<PMEvent>,
    commands: async_mpsc::Receiver<Command>,
    cancel: watch::Receiver<bool>,
    health: &health::SharedHealth,
) -> Result<()> {
    // Cancellation may drop setup safely: no input task exists until this completes.
    // Keep this select outside the media loop so held inputs still get explicit cleanup.
    let mut setup_cancel = cancel.clone();
    let setup = async {
        let audio = bounded("Audio transport", adapter.bind_udp(0)).await?;
        let video = bounded("Video transport", adapter.bind_udp(0)).await?;
        let host = adapter.host_ip().to_string();
        let peer = adapter.peer_ip().to_string();
        // Compatible offer profile captured by the upstream implementation; not device identity.
        let info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        status(tx, "Opening touch and keyboard…");
        health::stage(health, 4);
        let mut hid = bounded(
            "Touch service",
            UniversalHidServiceClient::connect_rsd(adapter, rsd),
        )
        .await?;
        let indigo = bounded(
            "Keyboard service",
            IndigoHidClient::connect_rsd(adapter, rsd),
        )
        .await?;
        let surfaces = bounded("Touchscreen discovery", hid.list_connected_services()).await?;
        let touch_id = surfaces
            .iter()
            .find(|s| {
                s.product
                    .as_deref()
                    .is_some_and(|p| p.to_lowercase().contains("touchscreen"))
            })
            .or_else(|| {
                surfaces
                    .iter()
                    .find(|s| s.primary_usage_page == Some(13) && s.primary_usage == Some(4))
            })
            .map(|s| s.service_id)
            .ok_or("No touchscreen surface is available. Unlock the iPhone.")?;
        let orientation = bounded(
            "Display orientation",
            OrientationServiceClient::connect_rsd(adapter, rsd),
        )
        .await?;
        // Rotation must not block media reception or share an in-flight query response.
        let rotation = bounded(
            "Rotation control",
            OrientationServiceClient::connect_rsd(adapter, rsd),
        )
        .await
        .ok();
        let pasteboard = bounded(
            "Pasteboard",
            PasteboardServiceClient::connect_rsd(adapter, rsd),
        )
        .await
        .ok();
        status(tx, "Starting screen sharing…");
        health::stage(health, 5);
        let audio_offer = build_screen_audio_offer(&uuid::Uuid::new_v4().to_string(), &info)
            .map_err(|e| e.to_string())?;
        let audio_response = bounded(
            "Screen session",
            display.start_media_stream(build_start_audio_parameters(
                &host,
                audio.local_port(),
                &peer,
                50000,
                audio_offer,
                140,
                session_id,
            )),
        )
        .await?;
        // The audio codec (AAC-ELD, 48kHz, 480-sample frames) isn't negotiable here.
        // Only the RTP payload type is used to sanity-check incoming packets, read from
        // the device's own echo of its negotiated streamConfig (the answer blob's SSRC
        // field does not match what the device's live RTP packets actually carry).
        let audio_payload_type =
            find_int(&audio_response, "RxPayloadType", 0).and_then(|v| u8::try_from(v).ok());
        let our_ssrc = uuid::Uuid::new_v4().as_u128() as u32;
        let call_id = uuid::Uuid::new_v4().to_string();
        let offer =
            build_screen_video_offer(&call_id, &info, our_ssrc).map_err(|e| e.to_string())?;
        let response = bounded(
            "Video negotiation",
            display.start_media_stream(build_start_video_parameters(
                &host,
                video.local_port(),
                &peer,
                50001,
                offer,
                140,
                1,
                session_id,
            )),
        )
        .await?;
        let answer = find_data(&response, "negotiatorAnswer", 0)
            .ok_or("No video negotiation answer from the iPhone.")?;
        let negotiated =
            parse_screen_video_answer(answer).map_err(|e| format!("Video negotiation: {e}"))?;
        Ok::<_, String>((
            audio,
            audio_payload_type,
            video,
            our_ssrc,
            call_id,
            negotiated,
            hid,
            indigo,
            pasteboard,
            touch_id,
            orientation,
            rotation,
        ))
    };
    let (
        audio,
        audio_payload_type,
        video,
        our_ssrc,
        call_id,
        negotiated,
        hid,
        indigo,
        pasteboard,
        touch_id,
        orientation,
        rotation,
    ) = tokio::select! {
        biased;
        _ = cancelled(&mut setup_cancel) => return Ok(()),
        result = setup => result?,
    };
    status(tx, "Connected · waiting for picture");
    let mut cancel_media = cancel.clone();
    let (input_stop_tx, input_stop_rx) = watch::channel(false);
    let (orientation_tx, orientation_rx) = watch::channel(orientation::Observation::initial());
    let orientation_worker = tokio::spawn(orientation::run(
        orientation,
        orientation_tx,
        input_stop_rx.clone(),
    ));
    let (refresh_tx, mut refresh_rx) = async_mpsc::channel(1);
    let input = tokio::spawn(input_loop(
        hid,
        indigo,
        pasteboard,
        touch_id,
        commands,
        input_stop_rx,
        refresh_tx,
        rotation,
        tx.clone(),
    ));
    let mut assembler = HevcAccessUnitAssembler::new(negotiated.payload_type, negotiated.ssrc);
    let mut timer = tokio::time::interval(Duration::from_millis(50));
    timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let started = tokio::time::Instant::now();
    let mut metrics = health::Health {
        stage: 6,
        ..Default::default()
    };
    let mut last_packet: Option<tokio::time::Instant> = None;
    let mut received = false;
    let mut frames = 0u16;
    let mut first_seq: Option<u16> = None;
    let mut relative_seq = 0u16;
    let mut fir = 0u8;
    let mut last_refresh = started - Duration::from_secs(1);
    let mut request_refresh = false;
    let mut config_revision = 0;
    let mut config_changed = started;
    let mut last_frame = started;
    // The offer names the device feedback port; the RTP source port is different.
    let remote_video_port = 50001;
    let trace = std::env::var_os("PM_TRACE").is_some();
    let mut audio_packets_seen: u64 = 0;
    if trace {
        eprintln!("audio: negotiated payload_type={audio_payload_type:?}");
    }
    let result = 'media: loop {
        tokio::select! {
            _ = cancelled(&mut cancel_media) => break Ok(()),
            _ = timer.tick() => {
                let observation = *orientation_rx.borrow();
                metrics.orientation_queries = observation.queries;
                metrics.orientation_max_ms = observation.max_ms;
                metrics.orientation_failures = u64::from(observation.failed);
                metrics.last_packet_age_ms = last_packet.map(|time| time.elapsed().as_millis() as u64);
                metrics.publish(health);
                if observation.failed {break Err("Display orientation stopped responding. Reconnecting to restore safe controls.".into());}
                if input.is_finished() {break Err("The input connection closed. Reconnect to continue.".into());}
                // A static screen can legitimately send no RTP for several seconds.
                // Orientation responses provide liveness; only time out stalled
                // assembly when packets still arrive or integrity was lost.
                let stalled = last_packet.is_some_and(|time| time.elapsed()<Duration::from_secs(1))
                    || metrics.queue_overflows>0 || metrics.discontinuities>0;
                if received && stalled && last_frame.elapsed()>Duration::from_secs(8) {break Err("The video pipeline stopped producing complete pictures. Reconnecting.".into());}
                if stalled && last_frame.elapsed()>Duration::from_secs(2) {request_refresh=true;}
                if !received && started.elapsed()>Duration::from_secs(20) {break Err("No complete video frame arrived. Unlock the phone, prepare it in Xcode, then reconnect.".into());}
                if first_seq.is_some() {
                    if let Err(error)=send_feedback(video.send_to(remote_video_port,build_rctl(our_ssrc,started.elapsed().as_millis() as u16,frames,relative_seq)), &mut metrics).await {break Err(error);}
                }
                if request_refresh && last_refresh.elapsed()>=Duration::from_millis(500) {
                    metrics.refresh_requests += 1;
                    if let Err(error)=send_feedback(video.send_to(remote_video_port,build_keyframe_request(our_ssrc,&call_id,negotiated.ssrc,&[],fir)), &mut metrics).await {break Err(error);}
                    fir=fir.wrapping_add(1);last_refresh=tokio::time::Instant::now();request_refresh=false;
                }
            }
            Some(_) = refresh_rx.recv() => {assembler.mark_stream_discontinuity();request_refresh=true;}
            audio_packet = audio.recv() => {
                let packet = match audio_packet {Ok(p) => p, Err(_) => break Err("The USB media connection closed.".into())};
                if is_rtcp(&packet.data) {continue;}
                let Some(rtp) = RtpPacket::parse(&packet.data) else {
                    if trace {eprintln!("audio: {} bytes did not parse as RTP", packet.data.len());}
                    continue;
                };
                if let Some(pt) = audio_payload_type { if rtp.payload_type != pt {
                    if trace {eprintln!("audio: dropped, payload_type {} != negotiated {pt}", rtp.payload_type);}
                    continue;
                }}
                if rtp.payload.is_empty() {continue;}
                audio_packets_seen += 1;
                if trace && audio_packets_seen == 1 {
                    eprintln!("audio: first accepted packet, pt={} ssrc={:#010x} payload_len={}", rtp.payload_type, rtp.ssrc, rtp.payload.len());
                }
                let event = PMEvent {kind: 7, values: [rtp.timestamp, 0, 0, 0, 0], parts: [rtp.payload.to_vec(), vec![], vec![], vec![]]};
                if let Err(mpsc::TrySendError::Full(_)) = audio_tx.try_send(event) {
                    if trace {eprintln!("audio: queue full; dropping a packet");}
                }
            }
            packet = video.recv() => {
                let packet=match packet {Ok(p)=>p,Err(_)=>break Err("The USB video connection closed.".into())};
                if is_rtcp(&packet.data) {continue;}
                let Some(rtp)=RtpPacket::parse(&packet.data) else {continue;};
                if rtp.payload_type!=negotiated.payload_type || rtp.ssrc!=negotiated.ssrc {continue;}
                let packet_time = tokio::time::Instant::now();
                metrics.video_packets += 1;
                if let Some(last) = last_packet { metrics.max_packet_gap_ms = metrics.max_packet_gap_ms.max(packet_time.duration_since(last).as_millis() as u64); }
                last_packet = Some(packet_time);
                if first_seq.is_none() && trace {eprintln!("video sender port: {}",packet.source_port);}

                let base=*first_seq.get_or_insert(rtp.sequence_number);
                let candidate=rtp.sequence_number.wrapping_sub(base);
                if candidate.wrapping_sub(relative_seq)<0x8000 {relative_seq=candidate;}
                for event in assembler.push_packet(&rtp) {
                    match event {
                        HevcDepacketizerEvent::AccessUnit(unit) => {
                            metrics.assembled_frames += 1;
                            frames=frames.wrapping_add(1);
                            if let Err(error)=send_feedback(video.send_to(remote_video_port,build_frame_ack(our_ssrc,unit.rtp_timestamp)), &mut metrics).await {break 'media Err(error);}
                            if let Some(config)=assembler.parameter_sets() {
                                if config.revision != config_revision {
                                    config_changed=tokio::time::Instant::now();
                                    config_revision=config.revision;
                                }
                                let current_orientation=orientation_rx.borrow().value_for(config_changed, tokio::time::Instant::now());
                                let event=PMEvent {kind:2,values:[config.pixel_width,config.pixel_height,u32::from(unit.is_sync),unit.rtp_timestamp,current_orientation],
                                    parts:[unit.bytes,config.video_parameter_set,config.sequence_parameter_set,config.picture_parameter_set]};
                                match tx.try_send(event) {
                                    Ok(())=>{metrics.queued_frames+=1;received=true;last_frame=tokio::time::Instant::now();},
                                    Err(mpsc::TrySendError::Full(_))=>{metrics.queue_overflows+=1;if trace {eprintln!("encoded queue full; requesting intra refresh");}assembler.mark_stream_discontinuity();request_refresh=true;break;},
                                    Err(mpsc::TrySendError::Disconnected(_))=>{break 'media Ok(());},
                                }
                            }
                        }
                        HevcDepacketizerEvent::Discontinuity(reason)=>{metrics.discontinuities+=1;if trace {eprintln!("HEVC discontinuity: {reason:?}");}request_refresh=true;},
                        _=>{},
                    }
                }
            }
        }
    };
    if trace {
        eprintln!("audio: session ending, {audio_packets_seen} accepted packets total");
    }
    let _ = input_stop_tx.send(true);
    let _ = orientation_worker.await;
    metrics.publish(health);
    let _ = input.await; // Held inputs are released before stopping the owned media session.
    result
}

async fn send_feedback(
    send: impl std::future::Future<Output = std::io::Result<()>>,
    health: &mut health::Health,
) -> Result<()> {
    // The adapter response can otherwise wait indefinitely and prevent cleanup.
    match tokio::time::timeout(Duration::from_millis(250), send).await {
        Ok(Ok(())) => Ok(()),
        _ => {
            health.feedback_failures += 1;
            Err("The USB video feedback path stopped responding. Reconnecting.".into())
        }
    }
}

#[cfg(test)]
#[tokio::test(start_paused = true)]
async fn stuck_feedback_is_bounded_so_the_session_can_close() {
    let mut health = health::Health::default();
    let began = tokio::time::Instant::now();
    assert!(
        send_feedback(std::future::pending(), &mut health)
            .await
            .is_err()
    );
    assert_eq!(health.feedback_failures, 1);
    assert_eq!(began.elapsed(), Duration::from_millis(250));
}

async fn read_orientation(
    client: &mut OrientationServiceClient<Box<dyn ReadWrite>>,
) -> Result<u32> {
    let state = client
        .current_orientation()
        .await
        .map_err(|_| "Could not read display orientation. Reconnect the iPhone.".to_string())?;
    if std::env::var_os("PM_TRACE_ORIENTATION").is_some() {
        eprintln!(
            "device orientation: {:?}, non-flat: {:?}, locked: {}",
            state.orientation, state.non_flat_orientation, state.locked
        );
    }
    Ok(orientation_value(&state))
}

impl orientation::Source for OrientationServiceClient<Box<dyn ReadWrite>> {
    async fn read(&mut self) -> Result<u32> {
        read_orientation(self).await
    }
}

fn orientation_value(state: &OrientationState) -> u32 {
    let orientation = match &state.orientation {
        Orientation::FaceUp | Orientation::FaceDown | Orientation::Unknown(_) => {
            &state.non_flat_orientation
        }
        value => value,
    };
    match orientation {
        Orientation::Portrait => 0,
        Orientation::PortraitUpsideDown => 1,
        Orientation::LandscapeLeft => 2,
        Orientation::LandscapeRight => 3,
        _ => 4, // Keep video available; the UI disables input until orientation is known.
    }
}

async fn input_loop(
    mut hid: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    mut indigo: IndigoHidClient<Box<dyn ReadWrite>>,
    mut pasteboard: Option<PasteboardServiceClient<Box<dyn ReadWrite>>>,
    surface: u64,
    mut commands: async_mpsc::Receiver<Command>,
    mut stop: watch::Receiver<bool>,
    refresh: async_mpsc::Sender<()>,
    mut rotation: Option<OrientationServiceClient<Box<dyn ReadWrite>>>,
    events: mpsc::SyncSender<PMEvent>,
) {
    let mut keys = BTreeSet::new();
    let mut touch = None;
    // The HID gate needs a brief authentication settle, but video must drain immediately.
    tokio::select! {_=cancelled(&mut stop)=>return, _=tokio::time::sleep(Duration::from_millis(300))=>{}}
    loop {
        let cmd = tokio::select! { biased; _=cancelled(&mut stop)=>break, c=commands.recv()=>match c {Some(c)=>c,None=>break} };
        let command_timeout = if matches!(cmd, Command::Input(9 | 10, _, _)) {
            Duration::from_secs(2)
        } else if matches!(cmd, Command::PasteImage(..)) {
            // Covers the SET round-trip (large photos can be substantial even after
            // the Swift-side JPEG fallback), the settle delay, and keyboard sends on
            // top of it — a command that blows its timeout doesn't just fail, it tears
            // down and restarts the whole session (see the timeout match below), so
            // this needs real headroom, not just enough for the happy path.
            Duration::from_secs(5)
        } else {
            Duration::from_secs(1)
        };
        let operation = async {
            let (kind, a, b) = match cmd {
                Command::Input(kind, a, b) => (kind, a, b),
                Command::Paste(text) => {
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                    let Some(pasteboard) = pasteboard.as_mut() else {
                        return Err(idevice::IdeviceError::UnexpectedResponse(
                            "The iPhone pasteboard service is unavailable.".into(),
                        ));
                    };
                    pasteboard.set_text(&text, GENERAL_PASTEBOARD).await?;
                    for key in [227, 25] {
                        keys.insert(key);
                        indigo.send_keyboard(key as u64, ButtonState::Down).await?;
                    }
                    tokio::time::sleep(Duration::from_millis(40)).await;
                    for key in [25, 227] {
                        indigo.send_keyboard(key as u64, ButtonState::Up).await?;
                        keys.remove(&key);
                    }
                    return Ok(());
                }
                Command::PasteImage(bytes, uti) => {
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                    let Some(pasteboard) = pasteboard.as_mut() else {
                        return Err(idevice::IdeviceError::UnexpectedResponse(
                            "The iPhone pasteboard service is unavailable.".into(),
                        ));
                    };
                    pasteboard.set_image(&bytes, uti, GENERAL_PASTEBOARD).await?;
                    // Neither a 300ms nor a 1.5s pause here fixed a real ~1.3MB PNG photo
                    // pasting nothing while 420KB worked, with the transport layer itself
                    // already ruled out (set_image's .await blocks until the device acks the
                    // full flow-controlled HTTP/2 transfer — see xpc/http2/mod.rs). So this
                    // wasn't a timing problem: something about payloads in that range doesn't
                    // paste via a hardware-keyboard Cmd+V at all, timing aside. The real fix is
                    // the Swift side re-encoding to JPEG above a size threshold well under that
                    // range. Keeping a small settle margin here regardless, since it's cheap and
                    // wasn't shown to hurt.
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    for key in [227, 25] {
                        keys.insert(key);
                        indigo.send_keyboard(key as u64, ButtonState::Down).await?;
                    }
                    tokio::time::sleep(Duration::from_millis(40)).await;
                    for key in [25, 227] {
                        indigo.send_keyboard(key as u64, ButtonState::Up).await?;
                        keys.remove(&key);
                    }
                    return Ok(());
                }
            };
            match kind {
                1 if a <= 65535 && b <= 65535 => {
                    touch = Some((a as u16, b as u16));
                    hid.send_report(
                        surface,
                        build_touchscreen_report(
                            TOUCHSCREEN_STATE_CONTACT,
                            a as u16,
                            b as u16,
                            None,
                        ),
                    )
                    .await?;
                }
                2 => {
                    if let Some((x, y)) = touch {
                        hid.send_report(
                            surface,
                            build_touchscreen_report(TOUCHSCREEN_STATE_RELEASE, x, y, None),
                        )
                        .await?;
                        touch = None;
                    }
                }
                3 if a <= 255 => {
                    if keys.insert(a) {
                        indigo.send_keyboard(a as u64, ButtonState::Down).await?;
                    }
                }
                4 => {
                    if keys.contains(&a) {
                        indigo.send_keyboard(a as u64, ButtonState::Up).await?;
                        keys.remove(&a);
                    }
                }
                5 | 8 => {
                    for _ in 0..if kind == 8 { 2 } else { 1 } {
                        indigo.send_button(0x0c, 0x40, ButtonState::Down).await?;
                        tokio::time::sleep(Duration::from_millis(80)).await;
                        indigo.send_button(0x0c, 0x40, ButtonState::Up).await?;
                        tokio::time::sleep(Duration::from_millis(90)).await;
                    }
                }
                6 => {
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                }
                7 => {
                    let _ = refresh.try_send(());
                }
                9 | 10 => {
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                    let Some(client) = rotation.as_mut() else {
                        let _ = events.try_send(PMEvent::message(
                            6,
                            "Rotation control is unavailable. Reconnect to try again.",
                        ));
                        return Ok(());
                    };
                    let direction = if kind == 9 {
                        RotationDirection::Right
                    } else {
                        RotationDirection::Left
                    };
                    match tokio::time::timeout(Duration::from_millis(750), client.rotate(direction))
                        .await
                    {
                        Ok(Ok(state)) => {
                            let _ = events.try_send(PMEvent::message(
                                5,
                                serde_json::json!({
                                    "locked": state.locked,
                                })
                                .to_string(),
                            ));
                        }
                        _ => {
                            // A timed-out RemoteXPC request cannot safely share its next response.
                            rotation = None;
                            let _ = events.try_send(PMEvent::message(
                                6,
                                "The iPhone could not rotate. Reconnect before trying again.",
                            ));
                        }
                    }
                }
                // A fixed set of hardware buttons by ID; never an arbitrary HID usage.
                13 => {
                    let Some((page, usage)) = hardware_button(a) else {
                        return Ok(());
                    };
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                    indigo.send_button(page, usage, ButtonState::Down).await?;
                    tokio::time::sleep(Duration::from_millis(80)).await;
                    indigo.send_button(page, usage, ButtonState::Up).await?;
                }
                // Not an edge gesture (it starts mid-screen), so this is a synthesized
                // drag on the raw touchscreen surface rather than an IndigoDigitizerEvent.
                // Best-effort starting geometry; unverified against a live device.
                11 => {
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                    hid.drag(32_768, 19_660, 32_768, 36_044, 15, 15).await?;
                }
                // IndigoDigitizerEvent's dedicated edge-swipe API (DigitizerEdge::Top,
                // then ::Right) did not work live on either attempt. Trying the same
                // raw-touchscreen-drag approach that worked for Spotlight (kind 11)
                // instead, anchored near the top-right corner. Best-effort; unverified.
                12 => {
                    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
                    hid.drag(61_600, 1_966, 61_600, 26_214, 15, 15).await?;
                }
                _ => {}
            }
            Ok::<(), idevice::IdeviceError>(())
        };
        if !matches!(
            tokio::time::timeout(command_timeout, operation).await,
            Ok(Ok(()))
        ) {
            break;
        }
    }
    release(&mut hid, &mut indigo, surface, &mut touch, &mut keys).await;
    let _ = tokio::time::timeout(
        Duration::from_millis(300),
        indigo.send_button(0x0c, 0x40, ButtonState::Up),
    )
    .await;
}
/// Command 13's button IDs → (HID usage page, usage). Consumer-page codes as
/// used for the physical side and volume buttons.
fn hardware_button(id: u32) -> Option<(u64, u64)> {
    match id {
        1 => Some((0x0c, 0x30)), // Power: lock/sleep
        2 => Some((0x0c, 0xe9)), // Volume up
        3 => Some((0x0c, 0xea)), // Volume down
        _ => None,
    }
}
async fn release(
    hid: &mut UniversalHidServiceClient<Box<dyn ReadWrite>>,
    indigo: &mut IndigoHidClient<Box<dyn ReadWrite>>,
    surface: u64,
    touch: &mut Option<(u16, u16)>,
    keys: &mut BTreeSet<u32>,
) {
    let cleanup = async {
        if let Some((x, y)) = touch.take() {
            let _ = hid
                .send_report(
                    surface,
                    build_touchscreen_report(TOUCHSCREEN_STATE_RELEASE, x, y, None),
                )
                .await;
        }
        for key in std::mem::take(keys) {
            let _ = indigo.send_keyboard(key as u64, ButtonState::Up).await;
        }
    };
    let _ = tokio::time::timeout(Duration::from_millis(700), cleanup).await;
}

#[cfg(test)]
mod button_tests {
    use super::hardware_button;
    #[test]
    fn only_known_button_ids_map_to_hid_usages() {
        assert_eq!(hardware_button(1), Some((0x0c, 0x30)));
        assert_eq!(hardware_button(2), Some((0x0c, 0xe9)));
        assert_eq!(hardware_button(3), Some((0x0c, 0xea)));
        for id in [0, 4, 0x30, 0xe9, u32::MAX] {
            assert_eq!(hardware_button(id), None);
        }
    }
}

#[cfg(test)]
mod orientation_tests {
    use super::*;
    #[test]
    fn current_orientation_takes_priority_over_non_flat_fallback() {
        let state = OrientationState {
            orientation: Orientation::Portrait,
            non_flat_orientation: Orientation::LandscapeRight,
            locked: true,
        };
        assert_eq!(orientation_value(&state), 0);
    }
    #[test]
    fn flat_device_uses_last_non_flat_orientation_without_guessing_unknown() {
        let mut state = OrientationState {
            orientation: Orientation::FaceUp,
            non_flat_orientation: Orientation::LandscapeLeft,
            locked: false,
        };
        assert_eq!(orientation_value(&state), 2);
        state.non_flat_orientation = Orientation::Unknown("unknown".into());
        assert_eq!(orientation_value(&state), 4);
    }
}
