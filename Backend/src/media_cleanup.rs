//! Confirm remote release without stopping streams belonging to another client.
//!
//! The current daemon requires numeric stream tokens for targeted StopRequest,
//! but does not expose a token for every session in start/status replies. Never
//! guess one or use stopAll: a status check followed by stopAll is not atomic.
//! Closing our transports stops keepalives; the negotiated short timeout reaps
//! our streams, including after cable loss or process death.
use crate::Display;
use idevice::{RsdService, rsd::RsdHandshake, tcp::handle::AdapterHandle};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(u32)]
pub enum ReleaseStatus {
    Absent = 1,
    AwaitingExpiry = 2,
    Unreachable = 3,
    TimedOut = 4,
    Unknown = 5,
    Rejected = 6,
}

pub fn classify(status: &plist::Value, owner: uuid::Uuid) -> ReleaseStatus {
    let Some(sessions) = status
        .as_dictionary()
        .and_then(|d| d.get("sessions"))
        .and_then(plist::Value::as_array)
    else {
        return ReleaseStatus::Unknown;
    };
    let mut unknown = false;
    for session in sessions {
        let id = [
            "connection",
            "options",
            "avcMediaStreamOptionClientSessionID",
            "uuid",
        ]
        .iter()
        .try_fold(session, |v, key| v.as_dictionary()?.get(*key))
        .and_then(plist::Value::as_string)
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
        match id {
            Some(id) if id == owner => return ReleaseStatus::AwaitingExpiry,
            Some(_) => {}
            None => unknown = true,
        }
    }
    if unknown {
        ReleaseStatus::Unknown
    } else {
        ReleaseStatus::Absent
    }
}

pub async fn inspect(
    adapter: &mut AdapterHandle,
    rsd: &mut RsdHandshake,
    owner: uuid::Uuid,
    budget: Duration,
) -> ReleaseStatus {
    let result = tokio::time::timeout(budget, async {
        // A new control connection; do not reuse a partially cancelled start RPC.
        Display::connect_rsd(adapter, rsd)
            .await?
            .get_media_stream_server_status()
            .await
    })
    .await;
    match result {
        Ok(Ok(status)) => classify(&status, owner),
        Ok(Err(idevice::IdeviceError::CoreDevice(_))) => ReleaseStatus::Rejected,
        Ok(Err(_)) => ReleaseStatus::Unreachable,
        Err(_) => ReleaseStatus::TimedOut,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session(id: uuid::Uuid) -> plist::Value {
        plist::to_value(&serde_json::json!({"connection":{"options":{
            "avcMediaStreamOptionClientSessionID":{"uuid":id.to_string()}
        }}}))
        .unwrap()
    }
    fn status(sessions: Vec<plist::Value>) -> plist::Value {
        let mut d = plist::Dictionary::new();
        d.insert("sessions".into(), plist::Value::Array(sessions));
        plist::Value::Dictionary(d)
    }
    #[test]
    fn never_claim_release_for_owned_or_unparseable_sessions() {
        let owner = uuid::Uuid::new_v4();
        assert_eq!(
            classify(&status(vec![session(owner)]), owner),
            ReleaseStatus::AwaitingExpiry
        );
        assert_eq!(
            classify(
                &status(vec![session(uuid::Uuid::new_v4()), session(owner)]),
                owner
            ),
            ReleaseStatus::AwaitingExpiry
        );
        assert_eq!(
            classify(
                &status(vec![plist::Value::String("malformed".into())]),
                owner
            ),
            ReleaseStatus::Unknown
        );
        assert_eq!(
            classify(&plist::Value::Dictionary(Default::default()), owner),
            ReleaseStatus::Unknown
        );
    }
    #[test]
    fn empty_and_replaced_sessions_are_absent_without_stopping_the_replacement() {
        let owner = uuid::Uuid::new_v4();
        assert_eq!(classify(&status(vec![]), owner), ReleaseStatus::Absent);
        assert_eq!(
            classify(&status(vec![session(uuid::Uuid::new_v4())]), owner),
            ReleaseStatus::Absent
        );
    }
}
