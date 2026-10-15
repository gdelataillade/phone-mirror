//! Session-owned RTCP keepalives. No task outlives the media receive loop.
use idevice::core_device::display_stream::{ReportBlock, build_receiver_report, build_sdes};

pub struct Keepalive {
    pub port: u16,
    local: u32,
    remote: u32,
    highest: Option<u32>,
}

impl Keepalive {
    pub fn negotiated(response: &plist::Value) -> Result<Self, String> {
        let config = response
            .as_dictionary()
            .and_then(|d| d.get("connection"))
            .and_then(plist::Value::as_dictionary)
            .and_then(|d| d.get("streamConfig"))
            .and_then(plist::Value::as_dictionary)
            .ok_or("Missing media keepalive configuration")?;
        let number = |key: &str| {
            config
                .get(key)
                .and_then(plist::Value::as_unsigned_integer)
                .ok_or_else(|| format!("Missing media keepalive field: {key}"))
        };
        let timeout = config
            .get("RTCPTimeoutInterval")
            .and_then(plist::Value::as_real);
        if config
            .get("RTCPTimeoutEnabled")
            .and_then(plist::Value::as_boolean)
            != Some(true)
            || !timeout
                .is_some_and(|seconds| seconds.is_finite() && seconds > 0.0 && seconds <= 20.0)
        {
            return Err("The iPhone did not accept the short media timeout".into());
        }
        let port =
            u16::try_from(number("SourcePort")?).map_err(|_| "Invalid media feedback port")?;
        // streamConfig uses the phone's perspective: RemoteSSRC is our receiver.
        let local = u32::try_from(number("RemoteSSRC")?).map_err(|_| "Invalid receiver SSRC")?;
        let remote = u32::try_from(number("LocalSSRC")?).map_err(|_| "Invalid sender SSRC")?;
        if port == 0 {
            return Err("Missing media feedback port".into());
        }
        Ok(Self {
            port,
            local,
            remote,
            highest: None,
        })
    }

    pub fn receive(&mut self, ssrc: u32, seq: u16) {
        if ssrc != self.remote {
            return;
        }
        self.highest = Some(match self.highest {
            None => u32::from(seq),
            Some(highest) => {
                let advance = seq.wrapping_sub(highest as u16);
                if advance < 0x8000 {
                    highest.wrapping_add(u32::from(advance))
                } else {
                    highest
                }
            }
        });
    }

    // Valid before any RTP arrives, including a silent audio session.
    pub fn packet(&self) -> Vec<u8> {
        let mut packet = build_receiver_report(
            self.local,
            &[ReportBlock {
                source_ssrc: self.remote,
                highest_seq: self.highest.unwrap_or(0),
                ..Default::default()
            }],
        );
        packet.extend(build_sdes(self.local, ""));
        packet
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn keepalive() -> Keepalive {
        Keepalive {
            port: 5000,
            local: 1,
            remote: 2,
            highest: None,
        }
    }
    #[test]
    fn silent_stream_still_has_compound_receiver_report() {
        let p = keepalive().packet();
        assert_eq!(p.len(), 44);
        assert_eq!(&p[..4], &[0x81, 201, 0, 7]);
        assert_eq!(&p[8..12], &2u32.to_be_bytes());
        assert_eq!(&p[16..20], &0u32.to_be_bytes());
        assert_eq!(&p[32..36], &[0x81, 202, 0, 2]);
    }
    #[test]
    fn sequence_wrap_and_late_packets_do_not_move_backwards() {
        let mut k = keepalive();
        k.receive(2, 65534);
        k.receive(2, 1);
        k.receive(2, 65535);
        k.receive(3, 100);
        assert_eq!(k.highest, Some(65537));
    }
    #[test]
    fn missing_negotiation_fails_instead_of_using_guessed_identifiers() {
        assert!(Keepalive::negotiated(&plist::Value::Dictionary(Default::default())).is_err());
    }
    #[test]
    fn negotiation_requires_finite_short_timeout_and_valid_feedback_address() {
        let response = |timeout: f64, port: u32, enabled: bool| {
            plist::to_value(&serde_json::json!({"connection":{"streamConfig":{
                "RTCPTimeoutInterval": timeout, "RTCPTimeoutEnabled": enabled,
                "SourcePort": port, "LocalSSRC": 2, "RemoteSSRC": 1
            }}}))
            .unwrap()
        };
        let k = Keepalive::negotiated(&response(20.0, 5000, true)).unwrap();
        assert_eq!((k.port, k.local, k.remote), (5000, 1, 2));
        for (timeout, port, enabled) in [
            (3600.0, 5000, true),
            (0.0, 5000, true),
            (20.0, 0, true),
            (20.0, 65536, true),
            (20.0, 5000, false),
        ] {
            assert!(Keepalive::negotiated(&response(timeout, port, enabled)).is_err());
        }
    }
}
