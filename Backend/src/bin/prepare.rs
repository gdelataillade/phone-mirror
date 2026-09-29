//! Device preparation diagnostics: `prepare COMMAND [UDID]`, where COMMAND is status,
//! images, rsd (advertised services), mount (what the app does), reveal or unmount.
//! Uses the first iPhone found (USB, else Wi-Fi) when no UDID is given. `unmount` exists only to test
//! preparation (it cannot remove Xcode's persistent image); the app never unmounts.
use phone_mirror_backend::{pm_devices, pm_string_free, prepare};
use std::{ffi::CStr, time::Instant};

fn first_device() -> Option<String> {
    unsafe {
        let json = pm_devices();
        let text = CStr::from_ptr(json).to_string_lossy().into_owned();
        pm_string_free(json);
        let list: serde_json::Value = serde_json::from_str(&text).ok()?;
        Some(
            list["devices"].as_array()?.first()?["id"]
                .as_str()?
                .to_owned(),
        )
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "status".into());
    let Some(udid) = args.next().or_else(first_device) else {
        eprintln!("No iPhone found.");
        std::process::exit(1)
    };
    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    let started = Instant::now();
    let result = runtime.block_on(async {
        match command.as_str() {
            "status" => Ok(prepare::status(&udid).await.to_string()),
            "mount" => prepare::mount(&udid).await.map(|mounted| {
                if mounted {
                    "mounted"
                } else {
                    "already mounted"
                }
                .into()
            }),
            "reveal" => prepare::reveal_developer_mode(&udid)
                .await
                .map(|()| "Developer Mode setting revealed".into()),
            "images" => prepare::mounted_images(&udid)
                .await
                .map(|v| format!("{v:#}")),
            "rsd" => prepare::service_names(&udid).await.map(|n| n.join("\n")),
            "unmount" => prepare::unmount(&udid).await.map(|()| "unmounted".into()),
            other => Err(format!("unknown command {other}")),
        }
    });
    let elapsed = started.elapsed().as_secs_f64();
    match result {
        Ok(text) => println!("{text}  ({elapsed:.2}s)"),
        Err(e) => {
            eprintln!("error: {e}  ({elapsed:.2}s)");
            std::process::exit(1)
        }
    }
}
