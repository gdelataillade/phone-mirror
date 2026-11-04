// Jackson Coxson
// Authenticate the paired certificate without imposing a public DNS identity.
use rustls::{
    ClientConfig, DigitallySignedStruct,
    client::{
        WebPkiServerVerifier,
        danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    },
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime, pem::PemObject},
};
use std::sync::Arc;

use crate::{IdeviceError, pairing_file::PairingFile};

#[derive(Debug)]
pub struct NoServerNameVerification {
    inner: Arc<WebPkiServerVerifier>,
    certificate: CertificateDer<'static>,
}

impl NoServerNameVerification {
    pub fn new(inner: Arc<WebPkiServerVerifier>, certificate: CertificateDer<'static>) -> Self {
        Self { inner, certificate }
    }
}

impl ServerCertVerifier for NoServerNameVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if _end_entity.as_ref() != self.certificate.as_ref() {
            return Err(rustls::Error::General(
                "Device certificate does not match pairing record".into(),
            ));
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls12_signature(_message, _cert, _dss)
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls13_signature(_message, _cert, _dss)
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

pub fn create_client_config(pairing_file: &PairingFile) -> Result<ClientConfig, IdeviceError> {
    let mut root_store = rustls::RootCertStore::empty();
    root_store.add(pairing_file.root_certificate.clone())?;
    let private_key = PrivateKeyDer::from_pem_slice(&pairing_file.host_private_key)?;

    let mut config = ClientConfig::builder()
        .with_root_certificates(root_store.clone())
        .with_client_auth_cert(vec![pairing_file.host_certificate.clone()], private_key)?;

    let inner = rustls::client::WebPkiServerVerifier::builder(Arc::new(root_store)).build()?;
    let verifier = Arc::new(NoServerNameVerification::new(
        inner,
        pairing_file.device_certificate.clone(),
    ));
    config.dangerous().set_certificate_verifier(verifier);

    Ok(config)
}
