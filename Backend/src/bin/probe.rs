//! Video stream probe: `probe [SECONDS] [UDID]`. Streams without decoding or saving
//! images and reports frame timing and the native counters. Uses the first iPhone found
//! unless a UDID is given; the backend then prefers USB and falls back to Wi-Fi.
use phone_mirror_backend::*;
use std::{
    ffi::{CStr, CString},
    time::{Duration, Instant},
};
fn main() {
    let mut args = std::env::args().skip(1);
    let duration = args.next().and_then(|s| s.parse().ok()).unwrap_or(20);
    let requested = args.next();
    unsafe {
        let id = match requested {
            Some(udid) => udid,
            None => {
                let json = pm_devices();
                let text = CStr::from_ptr(json).to_string_lossy().into_owned();
                pm_string_free(json);
                let list: serde_json::Value = serde_json::from_str(&text).expect("device JSON");
                let Some(device) = list["devices"].as_array().and_then(|a| a.first()) else {
                    eprintln!("{text}");
                    std::process::exit(1)
                };
                println!(
                    "Device: {} · iOS {} over {}",
                    device["name"], device["version"], device["transport"]
                );
                device["id"].as_str().unwrap().to_owned()
            }
        };
        let id = CString::new(id).unwrap();
        let handle = pm_start(id.as_ptr(), TRANSPORT_USB | TRANSPORT_WIFI);
        let start = Instant::now();
        let mut frames = 0u64;
        let mut first: Option<Duration> = None;
        let mut last: Option<Instant> = None;
        let mut max_gap = Duration::ZERO;
        let mut gaps_over_250ms = 0u32;
        let mut per_second: Vec<u32> = Vec::new();
        let mut failed = false;
        while start.elapsed() < Duration::from_secs(duration) {
            let event = pm_poll(handle, 100);
            if event.is_null() {
                continue;
            }
            match pm_event_kind(event) {
                2 => {
                    let now = Instant::now();
                    frames += 1;
                    if let Some(previous) = last {
                        let gap = now - previous;
                        max_gap = max_gap.max(gap);
                        if gap > Duration::from_millis(250) {
                            gaps_over_250ms += 1;
                        }
                    }
                    last = Some(now);
                    let second = (now - start).as_secs() as usize;
                    if per_second.len() <= second {
                        per_second.resize(second + 1, 0);
                    }
                    per_second[second] += 1;
                    if first.is_none() {
                        first = Some(start.elapsed());
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
        let health = pm_health(handle);
        let health_text = if health.is_null() {
            String::from("unavailable")
        } else {
            let text = CStr::from_ptr(health).to_string_lossy().into_owned();
            pm_string_free(health);
            text
        };
        pm_close(handle);
        let elapsed = start.elapsed().as_secs_f64();
        let streaming = first.map_or(0.0, |f| elapsed - f.as_secs_f64());
        println!("Complete frames: {frames}; elapsed {elapsed:.1}s");
        if frames > 0 {
            println!(
                "Average {:.1} fps after the first frame; longest gap {} ms; gaps over 250 ms: {gaps_over_250ms}",
                frames as f64 / streaming.max(0.001),
                max_gap.as_millis()
            );
            println!("Frames per second: {per_second:?}");
        }
        println!("Native counters: {health_text}");
        if failed || frames == 0 {
            std::process::exit(1);
        }
    }
}
