use phone_mirror_backend::*;
use std::{
    ffi::{CStr, CString},
    time::{Duration, Instant},
};
fn main() {
    unsafe {
        let json = pm_devices();
        let text = CStr::from_ptr(json).to_string_lossy().into_owned();
        pm_string_free(json);
        let list: serde_json::Value = serde_json::from_str(&text).expect("device JSON");
        let Some(device) = list["devices"].as_array().and_then(|a| a.first()) else {
            eprintln!("{text}");
            std::process::exit(1)
        };
        println!("USB device: {} · iOS {}", device["name"], device["version"]);
        let id = CString::new(device["id"].as_str().unwrap()).unwrap();
        let handle = pm_start(id.as_ptr());
        let duration = std::env::args()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(20);
        let start = Instant::now();
        let mut frames = 0;
        let mut failed = false;
        while start.elapsed() < Duration::from_secs(duration) {
            let event = pm_poll(handle, 100);
            if event.is_null() {
                continue;
            }
            match pm_event_kind(event) {
                2 => {
                    frames += 1;
                    if frames == 1 {
                        println!(
                            "First complete HEVC frame: {}×{} after {:.2}s",
                            pm_event_value(event, 0),
                            pm_event_value(event, 1),
                            start.elapsed().as_secs_f64()
                        );
                    }
                }
                kind => {
                    let mut len = 0;
                    let data = pm_event_data(event, 0, &mut len);
                    println!(
                        "{}: {}",
                        kind,
                        String::from_utf8_lossy(std::slice::from_raw_parts(data, len))
                    );
                    if kind == 3 {
                        failed = true;
                    }
                    if kind == 4 {
                        pm_event_free(event);
                        break;
                    }
                }
            }
            pm_event_free(event);
        }
        pm_close(handle);
        println!(
            "Complete frames: {frames}; elapsed {:.1}s",
            start.elapsed().as_secs_f64()
        );
        if failed || frames == 0 {
            std::process::exit(1);
        }
    }
}
