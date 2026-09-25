//! App listing, launch and termination for automation clients.
//!
//! Runs on its own lazily opened app-service connection, apart from the input loop:
//! a slow CoreDevice call must never delay touches or trip the input loop's
//! session-ending timeout. Requests are handled one at a time. Any failure drops
//! the connection, since a timed-out RemoteXPC request cannot safely share the next
//! response; the next request reconnects. No install or uninstall.
//!
//! Apps are listed with CoreDevice's streaming app list: on iOS 27 the one-shot
//! `listapps` feature accepted the request but never replied.
use idevice::{
    ReadWrite, RsdService,
    core_device::{AppListEntry, AppServiceClient},
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use serde_json::{Value, json};
use std::{sync::mpsc, time::Duration};
use tokio::sync::{mpsc as async_mpsc, watch};

/// HTTP-style status and a message safe to show to the automation client.
pub type Reply = std::result::Result<Value, (u16, String)>;
type Client = AppServiceClient<Box<dyn ReadWrite>>;

#[derive(Debug, PartialEq)]
pub enum Op {
    /// All user-visible apps, or only developer-installed builds.
    List {
        developer_only: bool,
    },
    Launch {
        bundle_id: String,
        restart: bool,
    },
    Terminate {
        bundle_id: String,
    },
}
pub struct Request {
    pub op: Op,
    pub reply: mpsc::SyncSender<Reply>,
}

/// Covers connecting as well as the call; the Swift side waits a little longer.
const TIMEOUT: Duration = Duration::from_secs(20);
const MAX_APPS: usize = 2000;
const SIGKILL: u32 = 9;

fn valid_bundle_id(value: &str) -> bool {
    (1..=255).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
}

/// Canonical request from the Swift layer, which has already validated the HTTP
/// body; this re-checks the boundary rather than trusting it.
pub fn parse(text: &str) -> std::result::Result<Op, String> {
    let value: Value = serde_json::from_str(text).map_err(|_| "Invalid app request")?;
    let object = value.as_object().ok_or("Invalid app request")?;
    let op = object.get("op").and_then(Value::as_str).unwrap_or("");
    let allowed: &[&str] = match op {
        "list" => &["op", "scope"],
        "launch" => &["op", "bundleID", "restart"],
        "terminate" => &["op", "bundleID"],
        _ => return Err("Unknown app operation".into()),
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err("Unexpected app request field".into());
    }
    let flag = |name: &str| match object.get(name) {
        None => Ok(false),
        Some(value) => value.as_bool().ok_or(format!("{name} must be a boolean")),
    };
    let bundle_id = || match object.get("bundleID").and_then(Value::as_str) {
        Some(id) if valid_bundle_id(id) => Ok(id.to_owned()),
        _ => Err("bundleID must be 1–255 letters, digits, dots or hyphens".to_string()),
    };
    Ok(match op {
        "list" => Op::List {
            developer_only: match object.get("scope").map(Value::as_str) {
                None | Some(Some("all")) => false,
                Some(Some("developer")) => true,
                _ => return Err("scope must be all or developer".into()),
            },
        },
        "launch" => Op::Launch {
            bundle_id: bundle_id()?,
            restart: flag("restart")?,
        },
        _ => Op::Terminate {
            bundle_id: bundle_id()?,
        },
    })
}

fn percent_decoded(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = |b: u8| (b as char).to_digit(16);
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(high), Some(low)) = (hex(bytes[i + 1]), hex(bytes[i + 2]))
        {
            out.push((high * 16 + low) as u8);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
/// Process executables are file URLs; app paths are plain paths. Either may carry
/// the /private prefix of iOS's /var symlink.
fn normalized(path: &str) -> String {
    let path = percent_decoded(path.strip_prefix("file://").unwrap_or(path));
    let path = path
        .strip_prefix("/private")
        .map(str::to_owned)
        .unwrap_or(path);
    path.trim_end_matches('/').to_owned()
}
/// True when the executable lives inside the app bundle (not a sibling prefix).
pub fn executable_belongs_to(executable: &str, app_path: &str) -> bool {
    let (executable, app) = (normalized(executable), normalized(app_path));
    !app.is_empty()
        && executable.len() > app.len()
        && executable.starts_with(&app)
        && executable.as_bytes()[app.len()] == b'/'
}

pub async fn run(
    mut adapter: AdapterHandle,
    mut rsd: RsdHandshake,
    mut requests: async_mpsc::Receiver<Request>,
    mut stop: watch::Receiver<bool>,
) {
    let mut client: Option<Client> = None;
    loop {
        let request = tokio::select! {
            biased;
            _ = super::cancelled(&mut stop) => break,
            request = requests.recv() => match request { Some(r) => r, None => break },
        };
        let result = tokio::select! {
            biased;
            _ = super::cancelled(&mut stop) => Err((503, "The iPhone session closed.".into())),
            result = tokio::time::timeout(
                TIMEOUT, handle(&mut client, &mut adapter, &mut rsd, request.op)
            ) => result.unwrap_or_else(|_| Err((
                504,
                "The iPhone did not answer in time. Observe before retrying.".into(),
            ))),
        };
        if result.is_err() {
            client = None;
        }
        let _ = request.reply.try_send(result);
    }
}

/// Step names only (PM_TRACE), never app names or bundle IDs.
fn trace(step: &str) {
    if std::env::var_os("PM_TRACE").is_some() {
        eprintln!("apps: {step}");
    }
}

/// RsdHandshake::connect, without its generic provider: that future is not Send
/// for every lifetime, which tokio::spawn requires.
async fn connect(
    adapter: &mut AdapterHandle,
    rsd: &RsdHandshake,
) -> std::result::Result<Client, idevice::IdeviceError> {
    let port = rsd
        .services
        .get(Client::rsd_service_name().as_ref())
        .ok_or(idevice::IdeviceError::ServiceNotFound)?
        .port;
    let stream: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
    Client::from_stream(stream).await
}

fn device(context: &str) -> impl Fn(idevice::IdeviceError) -> (u16, String) + '_ {
    move |error| (502, format!("{context}: {error}"))
}

async fn handle(
    slot: &mut Option<Client>,
    adapter: &mut AdapterHandle,
    rsd: &mut RsdHandshake,
    op: Op,
) -> Reply {
    if slot.is_none() {
        trace("connecting");
        *slot = Some(connect(adapter, rsd).await.map_err(device("App service"))?);
        trace("connected");
    }
    let Some(client) = slot.as_mut() else {
        return Err((503, "App service unavailable".into()));
    };
    match op {
        Op::List { developer_only } => {
            let apps = installed_apps(client).await?;
            let executables = running_executables(client).await?;
            let mut list: Vec<Value> = apps
                .iter()
                .filter(|app| !developer_only || app.is_developer_app)
                .take(MAX_APPS)
                .map(|app| {
                    json!({
                        "name": app.name,
                        "bundleID": app.bundle_identifier,
                        "version": app.version,
                        "build": app.bundle_version,
                        "developer": app.is_developer_app,
                        "apple": app.is_first_party,
                        "running": executables
                            .iter()
                            .any(|exe| executable_belongs_to(exe, &app.path)),
                    })
                })
                .collect();
            list.sort_by_key(|app| app["name"].as_str().unwrap_or("").to_lowercase());
            Ok(json!({ "apps": list }))
        }
        Op::Launch { bundle_id, restart } => {
            installed_app(client, &bundle_id).await?;
            let launched = client
                .launch_application(&bundle_id, &[], restart, false, None, None, None)
                .await
                .map_err(|error| refused("launch", &bundle_id, error))?;
            Ok(json!({ "launched": true, "bundleID": bundle_id, "pid": launched.pid }))
        }
        Op::Terminate { bundle_id } => {
            let app = installed_app(client, &bundle_id).await?;
            let processes = client
                .list_processes()
                .await
                .map_err(device("Listing processes"))?;
            let pids: Vec<u32> = processes
                .iter()
                .filter(|process| {
                    process
                        .executable_url
                        .as_ref()
                        .is_some_and(|url| executable_belongs_to(&url.relative, &app.path))
                })
                .map(|process| process.pid)
                .collect();
            if pids.is_empty() {
                return Err((409, format!("{bundle_id} is not running.")));
            }
            for pid in &pids {
                client
                    .send_signal(*pid, SIGKILL)
                    .await
                    .map_err(|error| refused("stop", &bundle_id, error))?;
            }
            Ok(json!({ "terminated": true, "bundleID": bundle_id, "pids": pids }))
        }
    }
}

/// Every user-visible app: App Store, Apple and developer-installed. Despite its
/// name, includeDefaultApps is what adds App Store apps; without it only
/// developer builds are returned.
async fn installed_apps(
    client: &mut Client,
) -> std::result::Result<Vec<AppListEntry>, (u16, String)> {
    use futures::StreamExt;
    let stream = client.stream_apps(false, true, false, false, true);
    futures::pin_mut!(stream);
    let mut apps = Vec::new();
    while let Some(app) = stream.next().await {
        let app = app.map_err(device("Listing apps"))?;
        if !app.is_hidden && !app.is_app_clip {
            apps.push(app);
        }
    }
    Ok(apps)
}

async fn installed_app(
    client: &mut Client,
    bundle_id: &str,
) -> std::result::Result<AppListEntry, (u16, String)> {
    installed_apps(client)
        .await?
        .into_iter()
        .find(|app| app.bundle_identifier == bundle_id)
        .ok_or((404, format!("No installed app has bundle ID {bundle_id}.")))
}

/// The device's error is a debug dump of an NSError dictionary, including archived
/// binary data. Surface only its one-line failure reason.
fn refused(action: &str, bundle_id: &str, error: idevice::IdeviceError) -> (u16, String) {
    let reason = failure_reason(&error.to_string());
    let reason = reason.map(|r| format!(": {r}")).unwrap_or_default();
    (
        409,
        format!("The iPhone did not {action} {bundle_id}{reason}"),
    )
}
fn failure_reason(debug: &str) -> Option<String> {
    const KEY: &str = "\"NSLocalizedFailureReason\": String(\"";
    let start = debug.find(KEY)? + KEY.len();
    let reason: String = debug[start..]
        .split("\")")
        .next()?
        .chars()
        .take(300)
        .collect();
    (!reason.is_empty()).then_some(reason)
}

async fn running_executables(
    client: &mut Client,
) -> std::result::Result<Vec<String>, (u16, String)> {
    Ok(client
        .list_processes()
        .await
        .map_err(device("Listing processes"))?
        .into_iter()
        .filter_map(|process| process.executable_url.map(|url| url.relative))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn executables_match_their_own_bundle_only() {
        let app = "/private/var/containers/Bundle/Application/ABC/My App.app";
        assert!(executable_belongs_to(
            "file:///private/var/containers/Bundle/Application/ABC/My%20App.app/My%20App",
            app
        ));
        assert!(executable_belongs_to(
            "file:///var/containers/Bundle/Application/ABC/My%20App.app/My%20App",
            app
        ));
        assert!(executable_belongs_to(
            "file:///Applications/Preferences.app/Preferences",
            "/Applications/Preferences.app/"
        ));
        // A sibling bundle sharing a name prefix, the bundle itself, and empty paths.
        assert!(!executable_belongs_to(
            "file:///Applications/PreferencesExtra.app/PreferencesExtra",
            "/Applications/Preferences.app"
        ));
        assert!(!executable_belongs_to(
            "file:///Applications/Preferences.app",
            "/Applications/Preferences.app"
        ));
        assert!(!executable_belongs_to("file:///anything", ""));
        assert!(!executable_belongs_to("file:///x%2", "/x"));
    }
    #[test]
    fn device_errors_are_reduced_to_their_failure_reason() {
        let dump = r#"device returned an error: Dictionary({"userInfoWithNSSecureCoding": Data([98, 112]), "userInfo": Dictionary({"NSLocalizedFailureReason": String("The requested application com.example.x is not installed."), "NSLocalizedDescription": String("The application failed to launch.")})})"#;
        assert_eq!(
            failure_reason(dump).as_deref(),
            Some("The requested application com.example.x is not installed.")
        );
        assert_eq!(failure_reason("device returned an error: Integer(5)"), None);
        let long = format!(
            r#""NSLocalizedFailureReason": String("{}")"#,
            "x".repeat(900)
        );
        assert_eq!(failure_reason(&long).map(|r| r.len()), Some(300));
    }
    #[test]
    fn requests_are_revalidated_at_the_native_boundary() {
        assert_eq!(
            parse(r#"{"op":"list"}"#),
            Ok(Op::List {
                developer_only: false
            })
        );
        assert_eq!(
            parse(r#"{"op":"list","scope":"all"}"#),
            Ok(Op::List {
                developer_only: false
            })
        );
        assert_eq!(
            parse(r#"{"op":"list","scope":"developer"}"#),
            Ok(Op::List {
                developer_only: true
            })
        );
        assert_eq!(
            parse(r#"{"op":"launch","bundleID":"com.apple.Preferences","restart":true}"#),
            Ok(Op::Launch {
                bundle_id: "com.apple.Preferences".into(),
                restart: true
            })
        );
        assert_eq!(
            parse(r#"{"op":"terminate","bundleID":"com.example.app-1"}"#),
            Ok(Op::Terminate {
                bundle_id: "com.example.app-1".into()
            })
        );
        for bad in [
            "",
            "[]",
            r#"{"op":"install","bundleID":"a"}"#,
            r#"{"op":"launch"}"#,
            r#"{"op":"launch","bundleID":""}"#,
            r#"{"op":"launch","bundleID":"com.x/../y"}"#,
            r#"{"op":"launch","bundleID":"com x"}"#,
            r#"{"op":"launch","bundleID":1}"#,
            r#"{"op":"launch","bundleID":"a","restart":"yes"}"#,
            r#"{"op":"terminate","bundleID":"a","restart":true}"#,
            r#"{"op":"list","system":true}"#,
            r#"{"op":"list","scope":"system"}"#,
            r#"{"op":"list","scope":true}"#,
        ] {
            assert!(parse(bad).is_err(), "{bad}");
        }
        assert!(
            parse(&format!(
                r#"{{"op":"launch","bundleID":"{}"}}"#,
                "a".repeat(256)
            ))
            .is_err()
        );
    }
}
