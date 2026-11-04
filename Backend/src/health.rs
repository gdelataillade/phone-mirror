//! Allowlisted session telemetry and recovery state. Never include identifiers or payloads.
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Stable numeric codes only; never derive these from error text or device data.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(u32)]
pub enum Failure {
    #[default]
    None = 0,
    Setup = 1,
    Orientation = 2,
    InputStopped = 3,
    InputTimeout = 4,
    InputError = 5,
    VideoTransport = 6,
    AudioTransport = 7,
    Feedback = 8,
    VideoRecovery = 9,
    FirstPicture = 10,
    Panic = 11,
    Runtime = 12,
    Other = 13,
}

#[derive(Clone, Default)]
pub struct Health {
    pub failure: Failure,
    pub stage: u32,
    pub cleanup_status: u32,
    pub cleanup_duration_ms: u64,
    pub video_packets: u64,
    pub assembled_frames: u64,
    pub queued_frames: u64,
    pub recovery_pending: bool,
    pub recovery_frame: u64,
    pub queue_overflows: u64,
    pub discontinuities: u64,
    pub refresh_requests: u64,
    pub orientation_queries: u64,
    pub orientation_max_ms: u64,
    pub orientation_failures: u64,
    pub max_packet_gap_ms: u64,
    pub last_packet_age_ms: Option<u64>,
    pub feedback_failures: u64,
}
pub type SharedHealth = Arc<Mutex<Health>>;

impl Health {
    pub fn json(&self) -> String {
        serde_json::json!({
            "failureCategory": self.failure as u32,
            "stage": self.stage,
            "cleanupStatus": self.cleanup_status,
            "cleanupDurationMs": self.cleanup_duration_ms,
            "videoPackets": self.video_packets,
            "assembledFrames": self.assembled_frames,
            "queuedFrames": self.queued_frames,
            "recoveryPending": self.recovery_pending,
            "recoveryFrame": self.recovery_frame,
            "queueOverflows": self.queue_overflows,
            "discontinuities": self.discontinuities,
            "refreshRequests": self.refresh_requests,
            "orientationQueries": self.orientation_queries,
            "orientationMaxMs": self.orientation_max_ms,
            "orientationFailures": self.orientation_failures,
            "maxPacketGapMs": self.max_packet_gap_ms,
            "lastPacketAgeMs": self.last_packet_age_ms,
            "feedbackFailures": self.feedback_failures,
        })
        .to_string()
    }
    pub fn publish(&self, shared: &SharedHealth) {
        if let Ok(mut value) = shared.lock() {
            // An input worker may have recorded the primary failure since the
            // media loop's last snapshot. Cleanup/later errors must not erase it.
            let failure = value.failure;
            *value = self.clone();
            if failure != Failure::None {
                value.failure = failure;
            }
        }
    }

    pub fn video_damaged(&mut self) {
        self.recovery_pending = true;
    }

    pub fn video_queued(&mut self, sync: bool) {
        self.queued_frames += 1;
        if sync && self.recovery_pending {
            // Only a queued sync picture repairs transport integrity. Swift
            // separately checks that this queue position was actually decoded.
            self.recovery_pending = false;
            self.recovery_frame = self.queued_frames;
        }
    }

    fn video_active(&self, packet_age: Option<Duration>) -> bool {
        self.recovery_pending || packet_age.is_some_and(|age| age < Duration::from_secs(1))
    }

    pub fn video_needs_refresh(&self, frame_age: Duration, packet_age: Option<Duration>) -> bool {
        self.video_active(packet_age) && frame_age > Duration::from_secs(2)
    }

    pub fn video_stalled(&self, frame_age: Duration, packet_age: Option<Duration>) -> bool {
        self.queued_frames > 0
            && self.video_active(packet_age)
            && frame_age > Duration::from_secs(8)
    }
}

pub fn record_failure(shared: &SharedHealth, failure: Failure) {
    if let Ok(mut value) = shared.lock() {
        if value.failure == Failure::None {
            value.failure = failure;
        }
    }
}

pub fn failed(shared: &SharedHealth, failure: Failure, error: impl Into<String>) -> String {
    record_failure(shared, failure);
    error.into()
}

pub fn input_failure<T, E>(
    result: &Result<Result<T, E>, tokio::time::error::Elapsed>,
) -> Option<Failure> {
    match result {
        Ok(Ok(_)) => None,
        Ok(Err(_)) => Some(Failure::InputError),
        Err(_) => Some(Failure::InputTimeout),
    }
}

pub fn record_unclassified_failure(shared: &SharedHealth) {
    if let Ok(mut value) = shared.lock() {
        if value.failure == Failure::None {
            value.failure = if value.stage > 0 && value.stage < 6 {
                Failure::Setup
            } else {
                Failure::Other
            };
        }
    }
}

pub fn stage(shared: &SharedHealth, stage: u32) {
    if let Ok(mut value) = shared.lock() {
        value.stage = stage;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn input_outcomes_are_classified_without_saving_error_text() {
        let shared = Arc::new(Mutex::new(Health::default()));
        let timeout = tokio::time::timeout(
            Duration::from_millis(10),
            std::future::pending::<Result<(), &str>>(),
        )
        .await;
        let failure = input_failure(&timeout).unwrap();
        assert_eq!(failure, Failure::InputTimeout);
        record_failure(&shared, failure);
        let error: Result<Result<(), &str>, tokio::time::error::Elapsed> =
            Ok(Err("private-device-detail"));
        assert_eq!(input_failure(&error), Some(Failure::InputError));
        assert_eq!(
            input_failure(&Ok::<_, tokio::time::error::Elapsed>(Ok::<_, &str>(()))),
            None
        );
        record_failure(&shared, Failure::InputError);
        let later = Health {
            stage: 6,
            video_packets: 42,
            ..Default::default()
        };
        later.publish(&shared);
        record_unclassified_failure(&shared);
        let health = shared.lock().unwrap();
        assert_eq!(health.failure, Failure::InputTimeout);
        assert_eq!(health.video_packets, 42);
        let json = health.json();
        assert!(json.contains("\"failureCategory\":4"));
        assert!(!json.contains("private-device-detail"));
    }

    #[test]
    fn classified_media_failure_survives_later_cleanup_and_setup_fallback() {
        for failure in [
            Failure::Orientation,
            Failure::InputStopped,
            Failure::VideoTransport,
            Failure::AudioTransport,
            Failure::Feedback,
            Failure::VideoRecovery,
            Failure::FirstPicture,
            Failure::Panic,
            Failure::Runtime,
        ] {
            let shared = Arc::new(Mutex::new(Health::default()));
            let error = failed(&shared, failure, "private transport error");
            assert_eq!(error, "private transport error"); // Existing app error behavior is unchanged.
            Health::default().publish(&shared);
            record_unclassified_failure(&shared);
            assert_eq!(shared.lock().unwrap().failure, failure);
            assert!(
                !shared
                    .lock()
                    .unwrap()
                    .json()
                    .contains("private transport error")
            );
        }
        let setup = Arc::new(Mutex::new(Health {
            stage: 4,
            ..Default::default()
        }));
        record_unclassified_failure(&setup);
        assert_eq!(setup.lock().unwrap().failure, Failure::Setup);
        let other = Arc::new(Mutex::new(Health {
            stage: 6,
            ..Default::default()
        }));
        record_unclassified_failure(&other);
        assert_eq!(other.lock().unwrap().failure, Failure::Other);
        let normal = Arc::new(Mutex::new(Health::default()));
        Health::default().publish(&normal);
        assert_eq!(normal.lock().unwrap().failure, Failure::None);
    }

    #[test]
    fn recovered_sync_allows_silence_without_resetting_error_counters() {
        let mut health = Health::default();
        health.video_queued(true);
        health.assembled_frames = 2;
        health.queue_overflows = 1;
        health.discontinuities = 1;
        health.video_damaged();
        assert!(health.video_needs_refresh(Duration::from_secs(3), None));
        assert!(health.video_stalled(Duration::from_secs(9), None));

        // A predicted picture cannot acknowledge recovery.
        health.assembled_frames += 1;
        health.video_queued(false);
        assert!(health.recovery_pending);
        health.assembled_frames += 1;
        health.video_queued(true);
        assert!(!health.recovery_pending);
        assert_eq!(health.recovery_frame, 3);
        assert_eq!(health.queue_overflows, 1);
        assert_eq!(health.discontinuities, 1);
        let quiet = Some(Duration::from_secs(30));
        assert!(!health.video_needs_refresh(Duration::from_secs(30), quiet));
        assert!(!health.video_stalled(Duration::from_secs(30), quiet));
        let json: serde_json::Value = serde_json::from_str(&health.json()).unwrap();
        assert_eq!(json["recoveryFrame"], 3);
        assert_eq!(json["recoveryPending"], false);
    }

    #[test]
    fn new_damage_requires_another_sync_and_stalled_assembly_still_expires() {
        let mut health = Health::default();
        health.video_queued(true);
        health.video_damaged();
        assert!(!health.video_stalled(Duration::from_secs(8), None));
        assert!(health.video_stalled(Duration::from_secs(9), None));
        health.video_queued(true);
        let checkpoint = health.recovery_frame;
        health.video_queued(true); // Routine keyframes do not start new recovery.
        assert_eq!(health.recovery_frame, checkpoint);
        health.video_damaged(); // A later loss cannot reuse the older sync.
        health.video_queued(false);
        assert!(health.recovery_pending);
        assert!(health.video_stalled(Duration::from_secs(9), None));
        health.video_queued(true);
        assert!(!health.recovery_pending);
        assert!(health.recovery_frame > checkpoint);
        // Packets without complete frames must still trigger refresh/restart.
        let arriving = Some(Duration::from_millis(10));
        assert!(health.video_needs_refresh(Duration::from_secs(3), arriving));
        assert!(health.video_stalled(Duration::from_secs(9), arriving));
    }
}
