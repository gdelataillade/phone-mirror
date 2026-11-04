//! In-memory TLS peers with fresh synthetic keys; no device or pairing files.
//! Compile the exact private production verifier without widening its public API.
pub use idevice::{IdeviceError, pairing_file};
#[path = "../../Vendor/idevice/src/sni.rs"]
mod device_tls;

use rustls::{
    CertificateError, ClientConnection, Error, ServerConfig, ServerConnection, SignatureAlgorithm,
    SignatureScheme, SupportedProtocolVersion,
    pki_types::{CertificateDer, PrivateKeyDer, ServerName},
    sign::{CertifiedKey, Signer, SigningKey, SingleCertAndKey},
};
use std::{io::Cursor, sync::Arc};

#[derive(Debug)]
struct CorruptSignatureKey(Arc<dyn SigningKey>);
impl SigningKey for CorruptSignatureKey {
    fn choose_scheme(&self, offered: &[SignatureScheme]) -> Option<Box<dyn Signer>> {
        self.0
            .choose_scheme(offered)
            .map(|signer| Box::new(CorruptSignature(signer)) as Box<dyn Signer>)
    }
    fn algorithm(&self) -> SignatureAlgorithm {
        self.0.algorithm()
    }
}
#[derive(Debug)]
struct CorruptSignature(Box<dyn Signer>);
impl Signer for CorruptSignature {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, Error> {
        let mut signature = self.0.sign(message)?;
        *signature.last_mut().unwrap() ^= 1;
        Ok(signature)
    }
    fn scheme(&self) -> SignatureScheme {
        self.0.scheme()
    }
}

fn identity() -> (CertificateDer<'static>, Vec<u8>, Vec<u8>) {
    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec!["synthetic-device.invalid".into()]).unwrap();
    (
        cert.der().clone(),
        signing_key.serialize_der(),
        signing_key.serialize_pem().into_bytes(),
    )
}

fn handshake(
    version: &'static SupportedProtocolVersion,
    wrong_certificate: bool,
    corrupt_signature: bool,
) -> Result<(), Error> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (paired_certificate, device_key, _) = identity();
    let (host_certificate, _, host_key_pem) = identity();
    let pairing = pairing_file::PairingFile {
        device_certificate: paired_certificate.clone(),
        host_private_key: host_key_pem,
        host_certificate: host_certificate.clone(),
        root_private_key: vec![],
        root_certificate: host_certificate,
        system_buid: "synthetic".into(),
        host_id: "synthetic".into(),
        escrow_bag: None,
        wifi_mac_address: "00:00:00:00:00:00".into(),
        udid: None,
    };
    let (server_certificate, server_key) = if wrong_certificate {
        let (cert, key, _) = identity();
        (cert, key)
    } else {
        (paired_certificate, device_key)
    };
    let key =
        rustls::crypto::ring::sign::any_supported_type(&PrivateKeyDer::Pkcs8(server_key.into()))
            .unwrap();
    let key: Arc<dyn SigningKey> = if corrupt_signature {
        Arc::new(CorruptSignatureKey(key))
    } else {
        key
    };
    let certified = CertifiedKey::new(vec![server_certificate], key);
    let server_config = ServerConfig::builder_with_protocol_versions(&[version])
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(SingleCertAndKey::from(certified)));
    // DNS names deliberately differ: pairing pins identity without public DNS.
    let mut client = ClientConnection::new(
        Arc::new(device_tls::create_client_config(&pairing).unwrap()),
        ServerName::try_from("unrelated-name.invalid").unwrap(),
    )?;
    let mut server = ServerConnection::new(Arc::new(server_config))?;
    for _ in 0..16 {
        let mut bytes = Vec::new();
        client.write_tls(&mut bytes).unwrap();
        server.read_tls(&mut Cursor::new(bytes)).unwrap();
        server.process_new_packets()?;
        let mut bytes = Vec::new();
        server.write_tls(&mut bytes).unwrap();
        client.read_tls(&mut Cursor::new(bytes)).unwrap();
        client.process_new_packets()?;
        if !client.is_handshaking() && !server.is_handshaking() {
            assert_eq!(client.protocol_version(), Some(version.version));
            return Ok(());
        }
    }
    panic!("synthetic handshake did not complete");
}

#[test]
fn paired_peer_completes_tls12_and_tls13_without_dns_identity() {
    for version in [&rustls::version::TLS12, &rustls::version::TLS13] {
        handshake(version, false, false).unwrap();
    }
}

#[test]
fn valid_but_unpaired_certificate_is_rejected_in_tls12_and_tls13() {
    for version in [&rustls::version::TLS12, &rustls::version::TLS13] {
        assert!(
            matches!(handshake(version, true, false), Err(Error::General(message))
            if message.contains("does not match pairing record"))
        );
    }
}

#[test]
fn paired_certificate_with_invalid_handshake_signature_is_rejected_in_tls12_and_tls13() {
    for version in [&rustls::version::TLS12, &rustls::version::TLS13] {
        assert!(matches!(
            handshake(version, false, true),
            Err(Error::InvalidCertificate(CertificateError::BadSignature))
        ));
    }
}
