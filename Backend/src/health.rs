//! Numeric-only session telemetry. Never include identifiers, payloads or error text.
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
pub struct Health {
    pub stage: u32,
    pub video_packets: u64,
    pub assembled_frames: u64,
    pub queued_frames: u64,
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
            "stage": self.stage,
            "videoPackets": self.video_packets,
            "assembledFrames": self.assembled_frames,
            "queuedFrames": self.queued_frames,
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
            *value = self.clone();
        }
    }
}

pub fn stage(shared: &SharedHealth, stage: u32) {
    if let Ok(mut value) = shared.lock() {
        value.stage = stage;
    }
}
