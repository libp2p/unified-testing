use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::Arc;
use std::time::Instant;

use quinn::{ClientConfig, Connection, Endpoint, RecvStream, SendStream, ServerConfig};
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};

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
            min: 0.0,
            q1: 0.0,
            median: 0.0,
            q3: 0.0,
            max: 0.0,
            outliers: vec![],
            samples: vec![],
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

    Stats {
        min,
        q1,
        median,
        q3,
        max,
        outliers,
        samples: values.to_vec(),
    }
}

fn format_list(values: &[f64], decimals: usize) -> String {
    if values.is_empty() {
        return "[]".into();
    }
    let items: Vec<String> = values.iter().map(|v| format!("{v:.decimals$}")).collect();
    format!("[{}]", items.join(", "))
}

fn print_results(
    label: &str,
    iterations: usize,
    stats: &Stats,
    decimals: usize,
    unit: &str,
) {
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
    // Bind a UDP socket to an external address to find our default route IP
    if let Ok(sock) = UdpSocket::bind("0.0.0.0:0") {
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
    redis::cmd("SET")
        .arg(key)
        .arg(value)
        .query_async::<()>(&mut conn)
        .await?;
    Ok(())
}

async fn redis_get_poll(
    addr: &str,
    key: &str,
    timeout_secs: u64,
) -> Result<String, Box<dyn std::error::Error>> {
    let client = redis::Client::open(format!("redis://{addr}"))?;
    let mut conn = client.get_multiplexed_tokio_connection().await?;
    for _ in 0..timeout_secs {
        let result: Option<String> = redis::cmd("GET")
            .arg(key)
            .query_async(&mut conn)
            .await?;
        if let Some(val) = result {
            if !val.is_empty() {
                return Ok(val);
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
    Err(format!("timeout waiting for Redis key: {key}").into())
}

fn parse_multiaddr(multiaddr: &str) -> Result<SocketAddr, Box<dyn std::error::Error>> {
    // Format: /ip4/{IP}/udp/{PORT}/quic-v1
    let parts: Vec<&str> = multiaddr.split('/').collect();
    if parts.len() < 5 {
        return Err(format!("invalid multiaddr: {multiaddr}").into());
    }
    let ip: Ipv4Addr = parts[2].parse()?;
    let port: u16 = parts[4].parse()?;
    Ok(SocketAddr::new(IpAddr::V4(ip), port))
}

// ---------------------------------------------------------------------------
// TLS helpers
// ---------------------------------------------------------------------------

fn generate_self_signed_cert() -> (Vec<CertificateDer<'static>>, PrivatePkcs8KeyDer<'static>) {
    let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()]).unwrap();
    let cert_der = CertificateDer::from(cert.cert);
    let key_der = PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der());
    (vec![cert_der], key_der)
}

fn make_server_config() -> ServerConfig {
    let (certs, key) = generate_self_signed_cert();

    let mut server_crypto = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key.into())
        .unwrap();
    server_crypto.alpn_protocols = vec![b"perf".to_vec()];

    ServerConfig::with_crypto(Arc::new(
        quinn::crypto::rustls::QuicServerConfig::try_from(server_crypto).unwrap(),
    ))
}

fn make_client_config() -> ClientConfig {
    let mut client_crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(InsecureVerifier))
        .with_no_client_auth();
    client_crypto.alpn_protocols = vec![b"perf".to_vec()];

    ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(client_crypto).unwrap(),
    ))
}

#[derive(Debug)]
struct InsecureVerifier;

impl rustls::client::danger::ServerCertVerifier for InsecureVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

// ---------------------------------------------------------------------------
// Send zeros helper
// ---------------------------------------------------------------------------

async fn send_zeros(
    send: &mut SendStream,
    total: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    const ZEROS: [u8; 65536] = [0u8; 65536];
    let mut remaining = total;
    while remaining > 0 {
        let n = remaining.min(ZEROS.len() as u64) as usize;
        send.write_all(&ZEROS[..n]).await?;
        remaining -= n as u64;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Listener
// ---------------------------------------------------------------------------

async fn handle_stream(mut send: SendStream, mut recv: RecvStream) {
    // Read 8-byte header
    let mut header = [0u8; 8];
    if recv.read_exact(&mut header).await.is_err() {
        // Can't read header — just discard
        let _ = tokio::io::copy(&mut recv, &mut tokio::io::sink()).await;
        return;
    }

    let requested_bytes = u64::from_be_bytes(header);

    if requested_bytes == 0 {
        // Upload test — discard remaining data
        let _ = tokio::io::copy(&mut recv, &mut tokio::io::sink()).await;
    } else {
        // Download test — send requested bytes
        let _ = send_zeros(&mut send, requested_bytes).await;
        let _ = send.finish();
    }
}

async fn handle_connection(conn: Connection) {
    loop {
        match conn.accept_bi().await {
            Ok((send, recv)) => {
                tokio::spawn(handle_stream(send, recv));
            }
            Err(_) => return,
        }
    }
}

async fn run_listener(cfg: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let server_config = make_server_config();
    let endpoint = Endpoint::server(server_config, "0.0.0.0:4001".parse()?)?;

    let container_ip = get_container_ip();
    eprintln!("Detected container IP: {container_ip}");

    let multiaddr = format!("/ip4/{container_ip}/udp/4001/quic-v1");
    eprintln!("Publishing listener address to Redis: {multiaddr}");

    let key = format!("{}_listener_multiaddr", cfg.test_key);
    redis_set(&cfg.redis_addr, &key, &multiaddr).await?;
    eprintln!("Published to Redis (key: {key})");
    eprintln!("QUIC listener ready");

    loop {
        if let Some(incoming) = endpoint.accept().await {
            let conn = match incoming.await {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("Incoming connection failed: {e}");
                    continue;
                }
            };
            tokio::spawn(handle_connection(conn));
        }
    }
}

// ---------------------------------------------------------------------------
// Dialer
// ---------------------------------------------------------------------------

async fn dial(
    server_addr: SocketAddr,
    endpoint: &Endpoint,
) -> Result<Connection, Box<dyn std::error::Error>> {
    let conn = endpoint.connect(server_addr, "localhost")?.await?;
    Ok(conn)
}

async fn run_upload_test(
    server_addr: SocketAddr,
    endpoint: &Endpoint,
    bytes: u64,
    iterations: usize,
) -> Stats {
    let mut values = Vec::with_capacity(iterations);

    for i in 0..iterations {
        let conn = match dial(server_addr, endpoint).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Upload iteration {} dial failed: {e}", i + 1);
                continue;
            }
        };

        let start = Instant::now();

        let (mut send, _recv) = match conn.open_bi().await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Upload iteration {} stream failed: {e}", i + 1);
                conn.close(0u32.into(), b"");
                continue;
            }
        };

        // Send 8-byte header with value 0 (upload test)
        let header = 0u64.to_be_bytes();
        if let Err(e) = send.write_all(&header).await {
            eprintln!("Upload iteration {} header write failed: {e}", i + 1);
            conn.close(0u32.into(), b"");
            continue;
        }

        // Send N zero bytes
        if let Err(e) = send_zeros(&mut send, bytes).await {
            eprintln!("Upload iteration {} send failed: {e}", i + 1);
        }
        let _ = send.finish();

        let elapsed = start.elapsed().as_secs_f64();
        let gbps = (bytes as f64 * 8.0) / elapsed / 1e9;

        conn.close(0u32.into(), b"");

        values.push(gbps);
        eprintln!("  Iteration {}/{iterations}: {gbps:.2} Gbps", i + 1);
    }

    calculate_stats(&mut values)
}

async fn run_download_test(
    server_addr: SocketAddr,
    endpoint: &Endpoint,
    bytes: u64,
    iterations: usize,
) -> Stats {
    let mut values = Vec::with_capacity(iterations);

    for i in 0..iterations {
        let conn = match dial(server_addr, endpoint).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Download iteration {} dial failed: {e}", i + 1);
                continue;
            }
        };

        let start = Instant::now();

        let (mut send, mut recv) = match conn.open_bi().await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Download iteration {} stream failed: {e}", i + 1);
                conn.close(0u32.into(), b"");
                continue;
            }
        };

        // Send requested byte count
        let header = bytes.to_be_bytes();
        if let Err(e) = send.write_all(&header).await {
            eprintln!("Download iteration {} header write failed: {e}", i + 1);
            conn.close(0u32.into(), b"");
            continue;
        }
        let _ = send.finish();

        // Read exactly the expected number of bytes (counted read + FIN check,
        // matching the pattern used by quiche/tquic/tokio-quiche baselines)
        let mut buf = [0u8; 65536];
        let mut remaining = bytes;
        while remaining > 0 {
            let to_read = remaining.min(buf.len() as u64) as usize;
            match recv.read(&mut buf[..to_read]).await {
                Ok(Some(n)) if n > 0 => remaining -= n as u64,
                _ => break, // Ok(None) = FIN, Err = error
            }
        }

        let elapsed = start.elapsed().as_secs_f64();
        let gbps = (bytes as f64 * 8.0) / elapsed / 1e9;

        conn.close(0u32.into(), b"");

        values.push(gbps);
        eprintln!("  Iteration {}/{iterations}: {gbps:.2} Gbps", i + 1);
    }

    calculate_stats(&mut values)
}

async fn run_latency_test(
    server_addr: SocketAddr,
    endpoint: &Endpoint,
    iterations: usize,
) -> Stats {
    let mut values = Vec::with_capacity(iterations);

    for i in 0..iterations {
        let start = Instant::now();

        let conn = match dial(server_addr, endpoint).await {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Latency iteration {} dial failed: {e}", i + 1);
                continue;
            }
        };

        let (mut send, mut recv) = match conn.open_bi().await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Latency iteration {} stream failed: {e}", i + 1);
                conn.close(0u32.into(), b"");
                continue;
            }
        };

        // Request 1 byte
        let header = 1u64.to_be_bytes();
        let _ = send.write_all(&header).await;
        let _ = send.finish();

        let mut buf = [0u8; 1];
        let _ = recv.read_exact(&mut buf).await;

        let elapsed = start.elapsed().as_secs_f64();
        let latency_ms = elapsed * 1000.0;

        conn.close(0u32.into(), b"");

        values.push(latency_ms);
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

    let client_config = make_client_config();
    let mut endpoint = Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(client_config);

    // Upload test
    eprintln!("Running upload test ({} iterations)...", cfg.upload_iters);
    let upload_stats =
        run_upload_test(server_addr, &endpoint, cfg.upload_bytes, cfg.upload_iters).await;

    // Download test
    eprintln!(
        "Running download test ({} iterations)...",
        cfg.download_iters
    );
    let download_stats = run_download_test(
        server_addr,
        &endpoint,
        cfg.download_bytes,
        cfg.download_iters,
    )
    .await;

    // Latency test
    eprintln!(
        "Running latency test ({} iterations)...",
        cfg.latency_iters
    );
    let latency_stats =
        run_latency_test(server_addr, &endpoint, cfg.latency_iters).await;

    // Output results as YAML to stdout
    print_results("Upload", cfg.upload_iters, &upload_stats, 2, "Gbps");
    println!();
    print_results("Download", cfg.download_iters, &download_stats, 2, "Gbps");
    println!();
    print_results("Latency", cfg.latency_iters, &latency_stats, 3, "ms");

    eprintln!("All measurements complete!");
    endpoint.wait_idle().await;
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
