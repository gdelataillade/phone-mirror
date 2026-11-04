use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

async fn rejected(response: String) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = [0; 4096];
        stream.read(&mut request).await.unwrap();
        stream.write_all(response.as_bytes()).await.unwrap();
    });
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        idevice::http::get(format!("http://{address}/fixture")),
    )
    .await
    .unwrap();
    server.await.unwrap();
    assert!(result.is_err());
}

#[tokio::test]
async fn excessive_lengths_are_errors_not_panics() {
    rejected(format!(
        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n",
        usize::MAX
    ))
    .await;
    rejected(format!(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n",
        usize::MAX
    ))
    .await;
}
#[tokio::test]
async fn truncated_and_conflicting_framing_are_rejected() {
    rejected("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort".into()).await;
    rejected(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
            .into(),
    )
    .await;
}
