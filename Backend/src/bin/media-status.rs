//! Read-only media-session inspection. Never starts, stops, or prepares a stream.
use idevice::{
    RsdService,
    core_device::DisplayServiceClient,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use phone_mirror_backend::prepare::Tunnel;

fn summary(value: &plist::Value) -> serde_json::Value {
    // Allowlist fields; never print device identifiers, addresses, media or new
    // fields introduced by a future daemon.
    let d = value.as_dictionary();
    let sessions = d
        .and_then(|d| d.get("sessions"))
        .and_then(plist::Value::as_array);
    let streams = sessions.map(|sessions| sessions.iter().map(|session| {
        let connection = session.as_dictionary().and_then(|d| d.get("connection"))
            .and_then(plist::Value::as_dictionary);
        let config = connection.and_then(|d| d.get("streamConfig"))
            .and_then(plist::Value::as_dictionary);
        serde_json::json!({
            "type": connection.and_then(|d| d.get("type")).and_then(plist::Value::as_string)
                .filter(|s| *s == "audio" || *s == "video").unwrap_or("unknown"),
            "timeout": connection.and_then(|d| d.get("timeout")).and_then(plist::Value::as_unsigned_integer),
            "rtcpTimeoutEnabled": config.and_then(|d| d.get("RTCPTimeoutEnabled")).and_then(plist::Value::as_boolean),
            "rtcpTimeoutSeconds": config.and_then(|d| d.get("RTCPTimeoutInterval")).and_then(plist::Value::as_real),
        })
    }).collect::<Vec<_>>());
    serde_json::json!({
        "running": d.and_then(|d| d.get("running")).and_then(plist::Value::as_boolean),
        "sessions": streams,
    })
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tokio::time::timeout(std::time::Duration::from_secs(15), async {
        let mut mux = UsbmuxdConnection::default().await?;
        let devices = mux.get_devices().await?;
        let usb: Vec<_> = devices
            .iter()
            .filter(|d| d.connection_type == Connection::Usb)
            .collect();
        if usb.len() != 1 {
            return Err("Connect exactly one unlocked iPhone over USB".into());
        }
        let provider = usb[0].to_provider(UsbmuxdAddr::default(), "iPhoneMirror-status");
        let mut tunnel = Tunnel::open(&provider).await?;
        if !tunnel.has_developer_services() {
            return Err("Developer services unavailable; nothing was changed".into());
        }
        let mut display =
            DisplayServiceClient::connect_rsd(&mut tunnel.adapter, &mut tunnel.rsd).await?;
        let state = display.get_media_stream_server_status().await?;
        println!("{}", serde_json::to_string_pretty(&summary(&state))?);
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}
