use std::collections::HashMap;
use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket as StdUdpSocket};
use std::time::Instant;

use tokio::net::UdpSocket;
use tokio::sync::oneshot;
use tokio_quiche::metrics::DefaultMetrics;
use tokio_quiche::quic::{connect_with_config, HandshakeInfo};
use tokio_quiche::settings::{CertificateKind, Hooks, TlsCertificatePaths};
use tokio_quiche::socket::Socket;
use tokio_quiche::{
    listen, ApplicationOverQuic, ConnectionParams, QuicResult,
};
use tokio_stream::StreamExt;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

struct Config {
    is_dialer: bool,
    redis_addr: String,
    test_key: String,
    upload_bytes: u64,
    download_bytes: u64,
    upload_iters: usize,
    download_iters: usize,
    latency_iters: usize,
}

impl Config {
    fn from_env() -> Self {
        Self {
            is_dialer: env::var("IS_DIALER").unwrap_or_default() == "true",
            redis_addr: env::var("REDIS_ADDR").unwrap_or_else(|_| "redis:6379".into()),
            test_key: env::var("TEST_KEY").unwrap_or_else(|_| "default".into()),
            upload_bytes: env::var("UPLOAD_BYTES")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(1_073_741_824),
            download_bytes: env::var("DOWNLOAD_BYTES")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(1_073_741_824),
            upload_iters: env::var("UPLOAD_ITERATIONS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(10),
            download_iters: env::var("DOWNLOAD_ITERATIONS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(10),
            latency_iters: env::var("LATENCY_ITERATIONS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(100),
        }
    }
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

struct Stats {
    min: f64,
    q1: f64,
    median: f64,
    q3: f64,
    max: f64,
    outliers: Vec<f64>,
    samples: Vec<f64>,
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len() as f64;
    let index = (p / 100.0) * (n - 1.0);
    let lower = index.floor() as usize;
    let upper = index.ceil() as usize;
    if lower == upper {
        return sorted[lower];
    }
    let weight = index - lower as f64;
    sorted[lower] * (1.0 - weight) + sorted[upper] * weight
}

fn calculate_stats(values: &mut [f64]) -> Stats {
    if values.is_empty() {
        return Stats {
            min: 0.0, q1: 0.0, median: 0.0, q3: 0.0, max: 0.0,
            outliers: vec![], samples: vec![],
        };
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q1 = percentile(values, 25.0);
    let median = percentile(values, 50.0);
    let q3 = percentile(values, 75.0);
    let iqr = q3 - q1;
    let lower_fence = q1 - 1.5 * iqr;
    let upper_fence = q3 + 1.5 * iqr;

    let mut outliers = Vec::new();
    let mut non_outliers = Vec::new();
    for &v in values.iter() {
        if v < lower_fence || v > upper_fence {
            outliers.push(v);
        } else {
            non_outliers.push(v);
        }
    }
    let (min, max) = if non_outliers.is_empty() {
        (values[0], values[values.len() - 1])
    } else {
        (non_outliers[0], non_outliers[non_outliers.len() - 1])
    };
    Stats { min, q1, median, q3, max, outliers, samples: values.to_vec() }
}

fn format_list(values: &[f64], decimals: usize) -> String {
    if values.is_empty() { return "[]".into(); }
    let items: Vec<String> = values.iter().map(|v| format!("{v:.decimals$}")).collect();
    format!("[{}]", items.join(", "))
}

fn print_results(label: &str, iterations: usize, stats: &Stats, decimals: usize, unit: &str) {
    println!("# {label} measurement");
    println!("{}:", label.to_lowercase());
    println!("  iterations: {iterations}");
    println!("  min: {:.decimals$}", stats.min);
    println!("  q1: {:.decimals$}", stats.q1);
    println!("  median: {:.decimals$}", stats.median);
    println!("  q3: {:.decimals$}", stats.q3);
    println!("  max: {:.decimals$}", stats.max);
    println!("  outliers: {}", format_list(&stats.outliers, decimals));
    println!("  samples: {}", format_list(&stats.samples, decimals));
    println!("  unit: {unit}");
}

// ---------------------------------------------------------------------------
// Network helpers
// ---------------------------------------------------------------------------

fn get_container_ip() -> IpAddr {
    if let Ok(sock) = StdUdpSocket::bind("0.0.0.0:0") {
        if sock.connect("8.8.8.8:80").is_ok() {
            if let Ok(addr) = sock.local_addr() {
                if !addr.ip().is_loopback() && !addr.ip().is_unspecified() {
                    return addr.ip();
                }
            }
        }
    }
    IpAddr::V4(Ipv4Addr::UNSPECIFIED)
}

async fn redis_set(addr: &str, key: &str, value: &str) -> Result<(), Box<dyn std::error::Error>> {
    let client = redis::Client::open(format!("redis://{addr}"))?;
    let mut conn = client.get_multiplexed_tokio_connection().await?;
    redis::cmd("SET").arg(key).arg(value).query_async::<()>(&mut conn).await?;
    Ok(())
}

async fn redis_get_poll(addr: &str, key: &str, timeout_secs: u64) -> Result<String, Box<dyn std::error::Error>> {
    let client = redis::Client::open(format!("redis://{addr}"))?;
    let mut conn = client.get_multiplexed_tokio_connection().await?;
    for _ in 0..timeout_secs {
        let result: Option<String> = redis::cmd("GET").arg(key).query_async(&mut conn).await?;
        if let Some(val) = result {
            if !val.is_empty() { return Ok(val); }
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Err(format!("timeout waiting for Redis key: {key}").into())
}

fn parse_multiaddr(multiaddr: &str) -> Result<SocketAddr, Box<dyn std::error::Error>> {
    let parts: Vec<&str> = multiaddr.split('/').collect();
    if parts.len() < 5 { return Err(format!("invalid multiaddr: {multiaddr}").into()); }
    let ip: Ipv4Addr = parts[2].parse()?;
    let port: u16 = parts[4].parse()?;
    Ok(SocketAddr::new(IpAddr::V4(ip), port))
}

// ---------------------------------------------------------------------------
// TLS cert generation
// ---------------------------------------------------------------------------

struct TlsCertFiles {
    _dir: tempfile::TempDir,
    cert_path: String,
    key_path: String,
}

fn generate_tls_cert_files() -> TlsCertFiles {
    let dir = tempfile::tempdir().expect("failed to create temp dir");
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();

    let cert_path = dir.path().join("cert.pem");
    let key_path = dir.path().join("key.pem");

    std::fs::write(&cert_path, cert.cert.pem()).unwrap();
    std::fs::write(&key_path, cert.key_pair.serialize_pem()).unwrap();

    TlsCertFiles {
        _dir: dir,
        cert_path: cert_path.to_str().unwrap().to_string(),
        key_path: key_path.to_str().unwrap().to_string(),
    }
}

// ---------------------------------------------------------------------------
// Server: PerfServerApp
// ---------------------------------------------------------------------------

enum ServerStreamState {
    ReadingHeader { buf: [u8; 8], offset: usize },
    DiscardingUpload,
    SendingDownload { remaining: u64 },
    Done,
}

struct PerfServerApp {
    pkt_buf: Vec<u8>,
    streams: HashMap<u64, ServerStreamState>,
    active: bool,
}

impl PerfServerApp {
    fn new() -> Self {
        Self {
            pkt_buf: vec![0u8; 65535],
            streams: HashMap::new(),
            active: false,
        }
    }
}

impl ApplicationOverQuic for PerfServerApp {
    fn on_conn_established(
        &mut self, _qconn: &mut quiche::Connection, _info: &HandshakeInfo,
    ) -> QuicResult<()> {
        self.active = true;
        Ok(())
    }

    fn should_act(&self) -> bool {
        self.active
    }

    fn buffer(&mut self) -> &mut [u8] {
        &mut self.pkt_buf
    }

    fn wait_for_data(
        &mut self, _qconn: &mut quiche::Connection,
    ) -> impl std::future::Future<Output = QuicResult<()>> + Send {
        std::future::pending()
    }

    fn process_reads(&mut self, qconn: &mut quiche::Connection) -> QuicResult<()> {
        let readable: Vec<u64> = qconn.readable().collect();
        for stream_id in readable {
            self.streams.entry(stream_id).or_insert_with(|| ServerStreamState::ReadingHeader {
                buf: [0u8; 8],
                offset: 0,
            });

            let mut read_buf = [0u8; 65535];
            loop {
                let state = self.streams.get_mut(&stream_id).unwrap();
                match state {
                    ServerStreamState::ReadingHeader { buf, offset } => {
                        match qconn.stream_recv(stream_id, &mut read_buf) {
                            Ok((len, fin)) => {
                                let need = 8 - *offset;
                                let copy_len = len.min(need);
                                buf[*offset..*offset + copy_len]
                                    .copy_from_slice(&read_buf[..copy_len]);
                                *offset += copy_len;

                                if *offset >= 8 {
                                    let requested = u64::from_be_bytes(*buf);
                                    if requested == 0 {
                                        *state = ServerStreamState::DiscardingUpload;
                                    } else {
                                        *state = ServerStreamState::SendingDownload {
                                            remaining: requested,
                                        };
                                    }
                                    // If there's leftover data after header, process it
                                    // (for upload, it's data to discard)
                                } else if fin {
                                    *state = ServerStreamState::Done;
                                    break;
                                } else {
                                    break;
                                }
                            }
                            Err(quiche::Error::Done) => break,
                            Err(_) => {
                                *state = ServerStreamState::Done;
                                break;
                            }
                        }
                    }
                    ServerStreamState::DiscardingUpload => {
                        match qconn.stream_recv(stream_id, &mut read_buf) {
                            Ok((_len, fin)) => {
                                if fin {
                                    *state = ServerStreamState::Done;
                                    break;
                                }
                            }
                            Err(quiche::Error::Done) => break,
                            Err(_) => {
                                *state = ServerStreamState::Done;
                                break;
                            }
                        }
                    }
                    _ => break,
                }
            }
        }
        Ok(())
    }

    fn process_writes(&mut self, qconn: &mut quiche::Connection) -> QuicResult<()> {
        let zero_buf = [0u8; 65535];
        let stream_ids: Vec<u64> = self.streams.keys().copied().collect();
        for stream_id in stream_ids {
            let done = {
                let state = self.streams.get_mut(&stream_id).unwrap();
                if let ServerStreamState::SendingDownload { remaining } = state {
                    let mut mark_done = false;
                    while *remaining > 0 {
                        let chunk = (*remaining).min(zero_buf.len() as u64) as usize;
                        let fin = chunk as u64 == *remaining;
                        match qconn.stream_send(stream_id, &zero_buf[..chunk], fin) {
                            Ok(written) => {
                                *remaining -= written as u64;
                                if *remaining == 0 {
                                    mark_done = true;
                                }
                            }
                            Err(quiche::Error::Done) => break,
                            Err(_) => {
                                mark_done = true;
                                break;
                            }
                        }
                    }
                    mark_done
                } else {
                    false
                }
            };
            if done {
                self.streams.insert(stream_id, ServerStreamState::Done);
            }
        }
        // Clean up completed streams
        self.streams.retain(|_, s| !matches!(s, ServerStreamState::Done));
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Client: PerfClientApp
// ---------------------------------------------------------------------------

enum TestType {
    Upload { bytes: u64 },
    Download { bytes: u64 },
    Latency,
}

enum ClientPhase {
    SendingHeader { header: [u8; 8], offset: usize },
    SendingUploadData { remaining: u64 },
    ReceivingDownload { expected: u64, received: u64 },
    Done,
}

struct PerfClientApp {
    pkt_buf: Vec<u8>,
    test_type: TestType,
    result_tx: Option<oneshot::Sender<f64>>,
    start_time: Option<Instant>,
    phase: ClientPhase,
    active: bool,
}

impl PerfClientApp {
    fn new_upload(bytes: u64, result_tx: oneshot::Sender<f64>) -> Self {
        let mut header = [0u8; 8];
        header.copy_from_slice(&0u64.to_be_bytes());
        Self {
            pkt_buf: vec![0u8; 65535],
            test_type: TestType::Upload { bytes },
            result_tx: Some(result_tx),
            start_time: None,
            phase: ClientPhase::SendingHeader { header, offset: 0 },
            active: false,
        }
    }

    fn new_download(bytes: u64, result_tx: oneshot::Sender<f64>) -> Self {
        let mut header = [0u8; 8];
        header.copy_from_slice(&bytes.to_be_bytes());
        Self {
            pkt_buf: vec![0u8; 65535],
            test_type: TestType::Download { bytes },
            result_tx: Some(result_tx),
            start_time: None,
            phase: ClientPhase::SendingHeader { header, offset: 0 },
            active: false,
        }
    }

    fn new_latency(result_tx: oneshot::Sender<f64>) -> Self {
        let mut header = [0u8; 8];
        header.copy_from_slice(&1u64.to_be_bytes());
        Self {
            pkt_buf: vec![0u8; 65535],
            test_type: TestType::Latency,
            result_tx: Some(result_tx),
            start_time: None,
            phase: ClientPhase::SendingHeader { header, offset: 0 },
            active: false,
        }
    }

    fn complete(&mut self, value: f64, qconn: &mut quiche::Connection) {
        if let Some(tx) = self.result_tx.take() {
            let _ = tx.send(value);
        }
        let _ = qconn.close(true, 0, b"");
        self.phase = ClientPhase::Done;
        self.active = false;
    }
}

impl ApplicationOverQuic for PerfClientApp {
    fn on_conn_established(
        &mut self, _qconn: &mut quiche::Connection, _info: &HandshakeInfo,
    ) -> QuicResult<()> {
        self.start_time = Some(Instant::now());
        self.active = true;
        Ok(())
    }

    fn should_act(&self) -> bool {
        self.active
    }

    fn buffer(&mut self) -> &mut [u8] {
        &mut self.pkt_buf
    }

    fn wait_for_data(
        &mut self, _qconn: &mut quiche::Connection,
    ) -> impl std::future::Future<Output = QuicResult<()>> + Send {
        std::future::pending()
    }

    fn process_reads(&mut self, qconn: &mut quiche::Connection) -> QuicResult<()> {
        if matches!(self.phase, ClientPhase::Done) {
            return Ok(());
        }

        // Only read in download/latency tests after header has been sent
        if let ClientPhase::ReceivingDownload { expected, received } = &mut self.phase {
            let mut buf = [0u8; 65535];
            loop {
                match qconn.stream_recv(0, &mut buf) {
                    Ok((len, fin)) => {
                        *received += len as u64;
                        if *received >= *expected || fin {
                            let elapsed = self.start_time.unwrap().elapsed().as_secs_f64();
                            let value = match &self.test_type {
                                TestType::Download { bytes } => {
                                    (*bytes as f64 * 8.0) / elapsed / 1e9
                                }
                                TestType::Latency => elapsed * 1000.0,
                                _ => 0.0,
                            };
                            self.complete(value, qconn);
                            return Ok(());
                        }
                    }
                    Err(quiche::Error::Done) => break,
                    Err(_) => break,
                }
            }
        }
        Ok(())
    }

    fn process_writes(&mut self, qconn: &mut quiche::Connection) -> QuicResult<()> {
        loop {
            match &mut self.phase {
                ClientPhase::SendingHeader { header, offset } => {
                    // Determine fin: for upload, don't fin (more data coming);
                    // for download/latency, fin after header
                    let fin_after_header = !matches!(self.test_type, TestType::Upload { .. });
                    let remaining_header = &header[*offset..];
                    let fin = fin_after_header && remaining_header.len() <= 65535;

                    match qconn.stream_send(0, remaining_header, fin && remaining_header.len() == (8 - *offset)) {
                        Ok(written) => {
                            *offset += written;
                            if *offset >= 8 {
                                match &self.test_type {
                                    TestType::Upload { bytes } => {
                                        self.phase = ClientPhase::SendingUploadData {
                                            remaining: *bytes,
                                        };
                                    }
                                    TestType::Download { bytes } => {
                                        self.phase = ClientPhase::ReceivingDownload {
                                            expected: *bytes,
                                            received: 0,
                                        };
                                        return Ok(());
                                    }
                                    TestType::Latency => {
                                        self.phase = ClientPhase::ReceivingDownload {
                                            expected: 1,
                                            received: 0,
                                        };
                                        return Ok(());
                                    }
                                }
                            } else {
                                return Ok(());
                            }
                        }
                        Err(quiche::Error::Done) => return Ok(()),
                        Err(e) => return Err(Box::new(e)),
                    }
                }
                ClientPhase::SendingUploadData { remaining } => {
                    let zero_buf = [0u8; 65535];
                    while *remaining > 0 {
                        let chunk = (*remaining).min(zero_buf.len() as u64) as usize;
                        let fin = chunk as u64 == *remaining;
                        match qconn.stream_send(0, &zero_buf[..chunk], fin) {
                            Ok(written) => {
                                *remaining -= written as u64;
                            }
                            Err(quiche::Error::Done) => return Ok(()),
                            Err(e) => return Err(Box::new(e)),
                        }
                    }
                    // All upload data sent
                    let elapsed = self.start_time.unwrap().elapsed().as_secs_f64();
                    if let TestType::Upload { bytes } = &self.test_type {
                        let gbps = (*bytes as f64 * 8.0) / elapsed / 1e9;
                        self.complete(gbps, qconn);
                    }
                    return Ok(());
                }
                ClientPhase::ReceivingDownload { .. } | ClientPhase::Done => {
                    return Ok(());
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Listener
// ---------------------------------------------------------------------------

async fn run_listener(cfg: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let tls_files = generate_tls_cert_files();

    let mut settings = tokio_quiche::settings::QuicSettings::default();
    settings.alpn = vec![b"perf".to_vec()];
    settings.disable_client_ip_validation = true;

    let tls_cert = TlsCertificatePaths {
        cert: &tls_files.cert_path,
        private_key: &tls_files.key_path,
        kind: CertificateKind::X509,
    };
    let params = ConnectionParams::new_server(settings, tls_cert, Hooks::default());

    let socket = UdpSocket::bind("0.0.0.0:4001").await?;
    let mut listeners = listen([socket], params, DefaultMetrics)?;
    let accept_stream = &mut listeners[0];

    let container_ip = get_container_ip();
    eprintln!("Detected container IP: {container_ip}");

    let multiaddr = format!("/ip4/{container_ip}/udp/4001/quic-v1");
    eprintln!("Publishing listener address to Redis: {multiaddr}");

    let key = format!("{}_listener_multiaddr", cfg.test_key);
    redis_set(&cfg.redis_addr, &key, &multiaddr).await?;
    eprintln!("Published to Redis (key: {key})");
    eprintln!("QUIC listener ready");

    while let Some(conn) = accept_stream.next().await {
        let conn = conn?;
        conn.start(PerfServerApp::new());
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Dialer
// ---------------------------------------------------------------------------

async fn run_one_test(
    server_addr: SocketAddr,
    app: impl ApplicationOverQuic,
) -> Result<(), Box<dyn std::error::Error>> {
    let socket = UdpSocket::bind("0.0.0.0:0").await?;
    socket.connect(server_addr).await?;
    let socket: Socket<_, _> = socket.try_into()?;

    let mut settings = tokio_quiche::settings::QuicSettings::default();
    settings.alpn = vec![b"perf".to_vec()];
    // verify_peer defaults to false

    let params = ConnectionParams::new_client(settings, None, Hooks::default());
    let _conn = connect_with_config(socket, Some("localhost"), &params, app)
        .await
        .map_err(|e| -> Box<dyn std::error::Error> { Box::new(std::io::Error::other(e.to_string())) })?;
    Ok(())
}

async fn run_upload_test(server_addr: SocketAddr, bytes: u64, iterations: usize) -> Stats {
    let mut values = Vec::with_capacity(iterations);
    for i in 0..iterations {
        let (tx, rx) = oneshot::channel();
        let app = PerfClientApp::new_upload(bytes, tx);
        if let Err(e) = run_one_test(server_addr, app).await {
            eprintln!("Upload iteration {} connect failed: {e}", i + 1);
            continue;
        }
        match rx.await {
            Ok(gbps) => {
                values.push(gbps);
                eprintln!("  Iteration {}/{iterations}: {gbps:.2} Gbps", i + 1);
            }
            Err(e) => eprintln!("Upload iteration {} result failed: {e}", i + 1),
        }
    }
    calculate_stats(&mut values)
}

async fn run_download_test(server_addr: SocketAddr, bytes: u64, iterations: usize) -> Stats {
    let mut values = Vec::with_capacity(iterations);
    for i in 0..iterations {
        let (tx, rx) = oneshot::channel();
        let app = PerfClientApp::new_download(bytes, tx);
        if let Err(e) = run_one_test(server_addr, app).await {
            eprintln!("Download iteration {} connect failed: {e}", i + 1);
            continue;
        }
        match rx.await {
            Ok(gbps) => {
                values.push(gbps);
                eprintln!("  Iteration {}/{iterations}: {gbps:.2} Gbps", i + 1);
            }
            Err(e) => eprintln!("Download iteration {} result failed: {e}", i + 1),
        }
    }
    calculate_stats(&mut values)
}

async fn run_latency_test(server_addr: SocketAddr, iterations: usize) -> Stats {
    let mut values = Vec::with_capacity(iterations);
    for i in 0..iterations {
        let (tx, rx) = oneshot::channel();
        let app = PerfClientApp::new_latency(tx);
        if let Err(e) = run_one_test(server_addr, app).await {
            eprintln!("Latency iteration {} connect failed: {e}", i + 1);
            continue;
        }
        match rx.await {
            Ok(ms) => values.push(ms),
            Err(e) => eprintln!("Latency iteration {} result failed: {e}", i + 1),
        }
    }
    calculate_stats(&mut values)
}

async fn run_dialer(cfg: &Config) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("Running as dialer/client...");

    let key = format!("{}_listener_multiaddr", cfg.test_key);
    eprintln!("Waiting for listener address from Redis (key: {key})...");
    let multiaddr = redis_get_poll(&cfg.redis_addr, &key, 60).await?;
    eprintln!("Got listener address: {multiaddr} (key: {key})");

    let server_addr = parse_multiaddr(&multiaddr)?;
    eprintln!("Connecting to QUIC server: {server_addr}");

    eprintln!("Running upload test ({} iterations)...", cfg.upload_iters);
    let upload_stats = run_upload_test(server_addr, cfg.upload_bytes, cfg.upload_iters).await;

    eprintln!("Running download test ({} iterations)...", cfg.download_iters);
    let download_stats = run_download_test(server_addr, cfg.download_bytes, cfg.download_iters).await;

    eprintln!("Running latency test ({} iterations)...", cfg.latency_iters);
    let latency_stats = run_latency_test(server_addr, cfg.latency_iters).await;

    print_results("Upload", cfg.upload_iters, &upload_stats, 2, "Gbps");
    println!();
    print_results("Download", cfg.download_iters, &download_stats, 2, "Gbps");
    println!();
    print_results("Latency", cfg.latency_iters, &latency_stats, 3, "ms");

    eprintln!("All measurements complete!");
    Ok(())
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cfg = Config::from_env();

    let result = if cfg.is_dialer {
        run_dialer(&cfg).await
    } else {
        run_listener(&cfg).await
    };

    if let Err(e) = result {
        eprintln!("Fatal error: {e}");
        std::process::exit(1);
    }
}
