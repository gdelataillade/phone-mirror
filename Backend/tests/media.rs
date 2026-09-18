// Run the exact vendored assembler's adversarial packet fixtures through our build.
// The small module alias preserves its production RTP type path.
#[path = "../../Vendor/idevice/src/services/core_device/display_stream/rtp.rs"]
pub mod rtp;
mod core_device {
    pub mod display_stream {
        pub use crate::rtp;
    }
}
#[path = "../../Vendor/idevice/src/services/core_device/display_stream/hevc.rs"]
mod hevc;
