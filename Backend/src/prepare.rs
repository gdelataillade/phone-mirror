//! Prepares an iPhone for mirroring without opening Xcode.
//!
//! Screen streaming, touch and app control are developer services: they exist only while
//! Developer Mode is on and Apple's personalized Developer Disk Image (DDI) is mounted.
//! Xcode installs that image on the Mac on its first launch; this module reads it from
//! there (it is never bundled or downloaded), asks Apple's signing server to personalize
//! it for the phone exactly as Xcode does, and mounts it. It also reports each setup
//! prerequisite and can reveal the hidden Developer Mode setting.
use super::{Result, bounded};
use idevice::{
    IdeviceError, IdeviceService,
    amfi::AmfiClient,
    lockdown::LockdownClient,
    mobile_image_mounter::ImageMounter,
    provider::{IdeviceProvider, UsbmuxdProvider},
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

/// Where Xcode's first launch unpacks the iOS image (XcodeSystemResources.pkg).
pub const DDI_RESTORE_DIR: &str = "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore";
/// Mount point of the personalized image on the phone.
const MOUNT_PATH: &str = "/System/Developer";
/// Uploading ~16 MB and a round trip to Apple's signing server.
const MOUNT_TIMEOUT: Duration = Duration::from_secs(90);
const NO_IMAGE: &str =
    "Apple's developer components aren't on this Mac. Install Xcode and open it once.";

#[derive(Debug, PartialEq)]
pub struct DdiFiles {
    pub image: PathBuf,
    pub trust_cache: PathBuf,
    pub manifest: PathBuf,
}

fn manifest_path<'a>(identity: &'a plist::Value, component: &str) -> Option<&'a str> {
    identity
        .as_dictionary()?
        .get("Manifest")?
        .as_dictionary()?
        .get(component)?
        .as_dictionary()?
        .get("Info")?
        .as_dictionary()?
        .get("Path")?
        .as_string()
}

/// The personalized image and its trust cache, as named by the manifest (file names change
/// with every Xcode release).
pub fn ddi_files(dir: &Path) -> Result<DdiFiles> {
    let manifest = dir.join("BuildManifest.plist");
    let value = plist::Value::from_file(&manifest).map_err(|_| NO_IMAGE)?;
    let identities = value
        .as_dictionary()
        .and_then(|d| d.get("BuildIdentities"))
        .and_then(plist::Value::as_array)
        .ok_or("The developer disk image manifest on this Mac is unreadable.")?;
    let (image, trust_cache) = identities
        .iter()
        .find_map(|identity| {
            Some((
                manifest_path(identity, "PersonalizedDMG")?,
                manifest_path(identity, "LoadableTrustCache")?,
            ))
        })
        .ok_or("The developer disk image on this Mac has no personalized image.")?;
    // The manifest only ever names files inside its own directory.
    if [image, trust_cache]
        .iter()
        .any(|p| p.starts_with('/') || p.split('/').any(|part| part == ".."))
    {
        return Err("The developer disk image manifest on this Mac is invalid.".into());
    }
    let files = DdiFiles {
        image: dir.join(image),
        trust_cache: dir.join(trust_cache),
        manifest,
    };
    if !files.image.is_file() || !files.trust_cache.is_file() {
        return Err(
            "Apple's developer components on this Mac are incomplete. Open Xcode once to reinstall them."
                .into(),
        );
    }
    Ok(files)
}

async fn provider(udid: &str) -> Result<UsbmuxdProvider> {
    let mut mux = bounded("USB connection", UsbmuxdConnection::default()).await?;
    let device = bounded("Selected iPhone", mux.get_devices())
        .await?
        .into_iter()
        .find(|d| d.udid == udid && d.connection_type == Connection::Usb)
        .ok_or("Connect this iPhone by USB and unlock it.")?;
    Ok(device.to_provider(UsbmuxdAddr::default(), "iPhoneMirror"))
}

/// A readable reason for the failures a user can fix.
fn explain(error: &IdeviceError) -> Option<&'static str> {
    Some(match error {
        IdeviceError::DeveloperModeNotEnabled => "Turn on Developer Mode on the iPhone.",
        IdeviceError::DeviceLocked => "Unlock the iPhone, then try again.",
        // The phone doesn't know this Mac's pairing record.
        IdeviceError::InvalidHostID => {
            "Unlock the iPhone and tap Trust when it asks about this Mac."
        }
        _ => return None,
    })
}

/// Bounded like every other device call; user-fixable failures get plain words.
async fn step<T>(
    label: &str,
    f: impl std::future::Future<Output = std::result::Result<T, IdeviceError>>,
) -> Result<T> {
    match tokio::time::timeout(Duration::from_secs(12), f).await {
        Err(_) => Err(format!(
            "{label} timed out. Unlock the iPhone and check its USB connection."
        )),
        Ok(Err(e)) => Err(explain(&e).map_or_else(|| format!("{label}: {e}"), str::to_owned)),
        Ok(Ok(v)) => Ok(v),
    }
}

/// The developer image's build if one is mounted. Checks the mounter's list rather than
/// LookupImage: Xcode 27 installs the image as a persistent cryptex (it survives reboots),
/// which LookupImage does not report.
pub fn mounted_developer_image(entries: &[plist::Value]) -> Option<String> {
    entries
        .iter()
        .filter_map(plist::Value::as_dictionary)
        .find_map(|entry| {
            let mounted = entry.get("IsMounted").and_then(plist::Value::as_boolean) == Some(true);
            let developer = entry.get("MountPath").and_then(plist::Value::as_string)
                == Some(MOUNT_PATH)
                || entry
                    .get("PersonalizedImageType")
                    .and_then(plist::Value::as_string)
                    == Some("DeveloperDiskImage");
            (mounted && developer).then(|| {
                entry
                    .get("PersonalizedImageVersionInfo")
                    .and_then(plist::Value::as_dictionary)
                    .and_then(|info| info.get("ProductBuildVersion"))
                    .and_then(plist::Value::as_string)
                    .unwrap_or("unknown")
                    .to_owned()
            })
        })
}

async fn unique_chip_id(provider: &UsbmuxdProvider) -> Result<u64> {
    let mut lockdown = step("Trust check", LockdownClient::connect(provider)).await?;
    let pairing = step("Trust check", provider.get_pairing_file()).await?;
    step("Trust check", lockdown.start_session(&pairing)).await?;
    step(
        "Device identity",
        lockdown.get_value(Some("UniqueChipID"), None),
    )
    .await?
    .as_unsigned_integer()
    .ok_or_else(|| "The iPhone did not report its chip identifier.".into())
}

/// Each prerequisite as true, false or null (not checked because an earlier one failed),
/// plus the first problem found. Never modifies the phone.
pub async fn status(udid: &str) -> Value {
    let mut out = json!({
        "ddiOnMac": ddi_files(Path::new(DDI_RESTORE_DIR)).is_ok(),
        "connected": false, "trusted": null, "developerMode": null, "ddiMounted": null,
        "ddiVersion": null,
    });
    let provider = match provider(udid).await {
        Ok(p) => p,
        Err(e) => {
            out["detail"] = e.into();
            return out;
        }
    };
    out["connected"] = true.into();
    if let Err(e) = unique_chip_id(&provider).await {
        out["trusted"] = false.into();
        out["detail"] = e.into();
        return out;
    }
    out["trusted"] = true.into();
    let mut mounter = match step("Developer services", ImageMounter::connect(&provider)).await {
        Ok(m) => m,
        Err(e) => {
            out["detail"] = e.into();
            return out;
        }
    };
    match step("Developer Mode", mounter.query_developer_mode_status()).await {
        Ok(on) => out["developerMode"] = on.into(),
        Err(e) => {
            out["detail"] = e.into();
            return out;
        }
    }
    if out["developerMode"] == false {
        out["detail"] = "Turn on Developer Mode on the iPhone.".into();
        return out;
    }
    match step("Developer services", mounter.copy_devices()).await {
        Ok(entries) => {
            let version = mounted_developer_image(&entries);
            out["ddiMounted"] = version.is_some().into();
            out["ddiVersion"] = version.into();
        }
        Err(e) => out["detail"] = e.into(),
    }
    out
}

/// Mounts the image unless it already is. Returns whether this call mounted it.
pub async fn ensure_mounted(provider: &UsbmuxdProvider) -> Result<bool> {
    let mut mounter = step("Developer services", ImageMounter::connect(provider)).await?;
    let entries = step("Developer services", mounter.copy_devices()).await?;
    if mounted_developer_image(&entries).is_some() {
        return Ok(false);
    }
    let files = ddi_files(Path::new(DDI_RESTORE_DIR))?;
    // The mounter's docs ask for a lockdown query after it connects, which this is.
    let ecid = unique_chip_id(provider).await?;
    let read = |path: &Path| std::fs::read(path).map_err(|_| NO_IMAGE.to_string());
    let (image, trust_cache, manifest) = (
        read(&files.image)?,
        read(&files.trust_cache)?,
        read(&files.manifest)?,
    );
    match tokio::time::timeout(
        MOUNT_TIMEOUT,
        mounter.mount_personalized(provider, image, trust_cache, &manifest, None, ecid),
    )
    .await
    {
        Err(_) => Err(
            "Preparing the iPhone timed out. Check this Mac's internet connection: Apple signs the developer image for each iPhone."
                .into(),
        ),
        Ok(Err(e)) => Err(explain(&e).map_or_else(
            || format!("Could not prepare the iPhone's developer services ({e}). Check this Mac's internet connection and try again."),
            str::to_owned,
        )),
        Ok(Ok(())) => Ok(true),
    }
}

pub async fn mount(udid: &str) -> Result<bool> {
    ensure_mounted(&provider(udid).await?).await
}

/// Makes Settings › Privacy & Security › Developer Mode appear; the user still turns it on.
pub async fn reveal_developer_mode(udid: &str) -> Result<()> {
    let provider = provider(udid).await?;
    let mut amfi = step("Developer Mode", AmfiClient::connect(&provider)).await?;
    step("Developer Mode", amfi.reveal_developer_mode_option_in_ui()).await
}

/// Diagnostics only: everything the phone's image mounter reports as mounted.
pub async fn mounted_images(udid: &str) -> Result<Value> {
    let provider = provider(udid).await?;
    let mut mounter = step("Developer services", ImageMounter::connect(&provider)).await?;
    let entries = step("Developer services", mounter.copy_devices()).await?;
    Ok(json!({ "developerImage": mounted_developer_image(&entries), "entries": entries }))
}

/// Diagnostics only: undoes a mount so preparation can be tested. Not exposed to the app.
pub async fn unmount(udid: &str) -> Result<()> {
    let provider = provider(udid).await?;
    let mut mounter = step("Developer services", ImageMounter::connect(&provider)).await?;
    step("Unmount", mounter.unmount_image(MOUNT_PATH)).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(dir: &Path, image: &str, trust: &str) {
        let identity = |image: Option<&str>, trust: Option<&str>| {
            let mut m = plist::Dictionary::new();
            if let Some(image) = image {
                m.insert("PersonalizedDMG".into(), component(image));
            }
            if let Some(trust) = trust {
                m.insert("LoadableTrustCache".into(), component(trust));
            }
            let mut d = plist::Dictionary::new();
            d.insert("Manifest".into(), m.into());
            plist::Value::Dictionary(d)
        };
        fn component(path: &str) -> plist::Value {
            let mut info = plist::Dictionary::new();
            info.insert("Path".into(), path.into());
            let mut c = plist::Dictionary::new();
            c.insert("Info".into(), info.into());
            c.into()
        }
        let mut root = plist::Dictionary::new();
        // A Cryptex-only identity first, as in Xcode 27's manifest.
        root.insert(
            "BuildIdentities".into(),
            vec![identity(None, None), identity(Some(image), Some(trust))].into(),
        );
        plist::Value::Dictionary(root)
            .to_file_xml(dir.join("BuildManifest.plist"))
            .unwrap();
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pm-ddi-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Firmware")).unwrap();
        dir
    }

    #[test]
    fn image_paths_come_from_the_personalized_identity() {
        let dir = temp_dir("ok");
        manifest(&dir, "022-1.dmg", "Firmware/022-1.dmg.trustcache");
        std::fs::write(dir.join("022-1.dmg"), b"image").unwrap();
        std::fs::write(dir.join("Firmware/022-1.dmg.trustcache"), b"trust").unwrap();
        let files = ddi_files(&dir).unwrap();
        assert_eq!(files.image, dir.join("022-1.dmg"));
        assert_eq!(files.trust_cache, dir.join("Firmware/022-1.dmg.trustcache"));
        assert_eq!(files.manifest, dir.join("BuildManifest.plist"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn missing_incomplete_or_escaping_images_are_rejected() {
        let missing = temp_dir("missing");
        assert_eq!(ddi_files(&missing).unwrap_err(), NO_IMAGE);
        manifest(&missing, "022-1.dmg", "Firmware/022-1.dmg.trustcache");
        assert!(ddi_files(&missing).unwrap_err().contains("incomplete"));
        for (image, trust) in [
            ("../x.dmg", "t"),
            ("/etc/x.dmg", "t"),
            ("a.dmg", "Firmware/../../t"),
        ] {
            manifest(&missing, image, trust);
            assert!(
                ddi_files(&missing).unwrap_err().contains("invalid"),
                "{image} {trust}"
            );
        }
        let _ = std::fs::remove_dir_all(missing);
    }

    #[test]
    fn cryptex_backed_developer_image_counts_as_mounted() {
        // Shape reported by iOS 27 after Xcode 27 prepared the phone.
        let entry = |mounted: bool, path: &str| {
            let mut info = plist::Dictionary::new();
            info.insert("ProductBuildVersion".into(), "27A266a".into());
            let mut d = plist::Dictionary::new();
            d.insert("IsMounted".into(), mounted.into());
            d.insert("MountPath".into(), path.into());
            d.insert("DiskImageType".into(), "Personalized".into());
            d.insert("PersonalizedImageVersionInfo".into(), info.into());
            plist::Value::Dictionary(d)
        };
        assert_eq!(
            mounted_developer_image(&[entry(true, "/System/Developer")]).as_deref(),
            Some("27A266a")
        );
        assert_eq!(
            mounted_developer_image(&[entry(false, "/System/Developer")]),
            None
        );
        assert_eq!(
            mounted_developer_image(&[entry(true, "/private/var/other")]),
            None
        );
        assert_eq!(mounted_developer_image(&[]), None);
    }

    #[test]
    fn user_fixable_device_errors_read_plainly() {
        assert_eq!(
            explain(&IdeviceError::DeveloperModeNotEnabled),
            Some("Turn on Developer Mode on the iPhone.")
        );
        assert!(
            explain(&IdeviceError::DeviceLocked)
                .unwrap()
                .contains("Unlock")
        );
        assert!(
            explain(&IdeviceError::InvalidHostID)
                .unwrap()
                .contains("Trust")
        );
        assert_eq!(explain(&IdeviceError::NotFound), None);
    }
}
