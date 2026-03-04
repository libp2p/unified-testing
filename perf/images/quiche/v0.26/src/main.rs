use std::collections::HashMap;
use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket as StdUdpSocket};
use std::time::Instant;

use mio::net::UdpSocket;
use mio::{Events, Interest, Poll, Token};
use ring::rand::SecureRandom;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

struct AppConfig {
    is_dialer: bool,
    redis_addr: String,
    test_key: String,
    upload_bytes: u64,
    download_bytes: u64,
    upload_iters: usize,
    download_iters: usize,
    latency_iters: usize,
}

impl AppConfig {
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

fn redis_set_blocking(addr: &str, key: &str, value: &str) -> Result<(), Box<dyn std::error::Error>> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    rt.block_on(async {
        let client = redis::Client::open(format!("redis://{addr}"))?;
        let mut conn = client.get_multiplexed_tokio_connection().await?;
        redis::cmd("SET").arg(key).arg(value).query_async::<()>(&mut conn).await?;
        Ok(())
    })
}

fn redis_get_poll_blocking(addr: &str, key: &str, timeout_secs: u64) -> Result<String, Box<dyn std::error::Error>> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    rt.block_on(async {
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
    })
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
// SCID generation
// ---------------------------------------------------------------------------

fn generate_scid() -> quiche::ConnectionId<'static> {
    let mut scid_bytes = [0u8; quiche::MAX_CONN_ID_LEN];
    ring::rand::SystemRandom::new()
        .fill(&mut scid_bytes)
        .expect("failed to generate random SCID");
    quiche::ConnectionId::from_vec(scid_bytes.to_vec())
}

// ---------------------------------------------------------------------------
// Quiche config helpers
// ---------------------------------------------------------------------------

fn make_server_config(tls_files: &TlsCertFiles) -> quiche::Config {
    let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
    config.load_cert_chain_from_pem_file(&tls_files.cert_path).unwrap();
    config.load_priv_key_from_pem_file(&tls_files.key_path).unwrap();
    config.set_application_protos(&[b"perf"]).unwrap();
    config.set_max_idle_timeout(30_000);
    config.set_max_recv_udp_payload_size(65535);
    config.set_max_send_udp_payload_size(65535);
    config.set_initial_max_data(10_000_000_000);
    config.set_initial_max_stream_data_bidi_local(10_000_000_000);
    config.set_initial_max_stream_data_bidi_remote(10_000_000_000);
    config.set_initial_max_stream_data_uni(10_000_000_000);
    config.set_initial_max_streams_bidi(1000);
    config.set_initial_max_streams_uni(1000);
    config.set_disable_active_migration(true);
    config
}

fn make_client_config() -> quiche::Config {
    let mut config = quiche::Config::new(quiche::PROTOCOL_VERSION).unwrap();
    config.set_application_protos(&[b"perf"]).unwrap();
    config.verify_peer(false);
    config.set_max_idle_timeout(30_000);
    config.set_max_recv_udp_payload_size(65535);
    config.set_max_send_udp_payload_size(65535);
    config.set_initial_max_data(10_000_000_000);
    config.set_initial_max_stream_data_bidi_local(10_000_000_000);
    config.set_initial_max_stream_data_bidi_remote(10_000_000_000);
    config.set_initial_max_stream_data_uni(10_000_000_000);
    config.set_initial_max_streams_bidi(1000);
    config.set_initial_max_streams_uni(1000);
    config.set_disable_active_migration(true);
    config
}

// ---------------------------------------------------------------------------
// Flush outgoing packets
// ---------------------------------------------------------------------------

fn flush_egress(conn: &mut quiche::Connection, socket: &UdpSocket, peer: &SocketAddr) {
    let mut out = [0u8; 65535];
    loop {
        let (write, send_info) = match conn.send(&mut out) {
            Ok(v) => v,
            Err(quiche::Error::Done) => break,
            Err(e) => {
                eprintln!("send() failed: {e}");
                break;
            }
        };
        let _ = socket.send_to(&out[..write], send_info.to);
        let _ = peer; // peer used via send_info.to
    }
}

// ---------------------------------------------------------------------------
// Server stream state
// ---------------------------------------------------------------------------

enum ServerStreamState {
    ReadingHeader { buf: [u8; 8], offset: usize },
    DiscardingUpload,
    SendingDownload { remaining: u64 },
    Done,
}

// ---------------------------------------------------------------------------
// Listener
// ---------------------------------------------------------------------------

fn run_listener(cfg: &AppConfig) -> Result<(), Box<dyn std::error::Error>> {
    let tls_files = generate_tls_cert_files();
    let mut config = make_server_config(&tls_files);

    let mut poll = Poll::new()?;
    let mut socket = UdpSocket::bind("0.0.0.0:4001".parse()?)?;
    let local_addr = socket.local_addr()?;
    poll.registry().register(&mut socket, Token(0), Interest::READABLE)?;

    let container_ip = get_container_ip();
    eprintln!("Detected container IP: {container_ip}");

    let multiaddr = format!("/ip4/{container_ip}/udp/4001/quic-v1");
    eprintln!("Publishing listener address to Redis: {multiaddr}");

    let key = format!("{}_listener_multiaddr", cfg.test_key);
    redis_set_blocking(&cfg.redis_addr, &key, &multiaddr)?;
    eprintln!("Published to Redis (key: {key})");
    eprintln!("QUIC listener ready");

    let mut recv_buf = [0u8; 65535];
    let mut events = Events::with_capacity(1024);

    // Track connections by SCID
    let mut connections: HashMap<quiche::ConnectionId<'static>, quiche::Connection> = HashMap::new();
    let mut stream_states: HashMap<quiche::ConnectionId<'static>, HashMap<u64, ServerStreamState>> = HashMap::new();

    loop {
        // Determine timeout from all connections
        let timeout = connections.values()
            .filter_map(|c| c.timeout())
            .min();

        poll.poll(&mut events, timeout)?;

        // Read incoming packets
        'read: loop {
            let (len, from) = match socket.recv_from(&mut recv_buf) {
                Ok(v) => v,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break 'read,
                Err(e) => return Err(e.into()),
            };

            let pkt_buf = &mut recv_buf[..len];

            // Parse the packet header to find the connection
            let hdr = match quiche::Header::from_slice(pkt_buf, quiche::MAX_CONN_ID_LEN) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let conn = if !connections.contains_key(&hdr.dcid) {
                if hdr.ty != quiche::Type::Initial {
                    continue;
                }

                let scid = generate_scid();
                let conn = quiche::accept(
                    &scid,
                    None,
                    local_addr,
                    from,
                    &mut config,
                )?;
                let scid_owned = scid.into_owned();
                connections.insert(scid_owned.clone(), conn);
                stream_states.insert(scid_owned.clone(), HashMap::new());
                connections.get_mut(&scid_owned).unwrap()
            } else {
                connections.get_mut(&hdr.dcid).unwrap()
            };

            let recv_info = quiche::RecvInfo {
                from,
                to: local_addr,
            };

            let _ = conn.recv(pkt_buf, recv_info);
        }

        // Process all connections
        let conn_ids: Vec<quiche::ConnectionId<'static>> = connections.keys().cloned().collect();
        for cid in &conn_ids {
            let conn = connections.get_mut(cid).unwrap();

            if conn.is_closed() {
                connections.remove(cid);
                stream_states.remove(cid);
                continue;
            }

            // Handle timeouts
            conn.on_timeout();

            // Process readable streams
            let readable: Vec<u64> = conn.readable().collect();
            let streams = stream_states.get_mut(cid).unwrap();

            for stream_id in readable {
                streams.entry(stream_id).or_insert_with(|| ServerStreamState::ReadingHeader {
                    buf: [0u8; 8],
                    offset: 0,
                });

                let mut read_buf = [0u8; 65535];
                loop {
                    let state = streams.get_mut(&stream_id).unwrap();
                    match state {
                        ServerStreamState::ReadingHeader { buf, offset } => {
                            match conn.stream_recv(stream_id, &mut read_buf) {
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
                            match conn.stream_recv(stream_id, &mut read_buf) {
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

            // Process writable streams (send download data)
            let zero_buf = [0u8; 65535];
            let stream_ids: Vec<u64> = streams.keys().copied().collect();
            for stream_id in stream_ids {
                let done = {
                    let state = streams.get_mut(&stream_id).unwrap();
                    if let ServerStreamState::SendingDownload { remaining } = state {
                        let mut mark_done = false;
                        while *remaining > 0 {
                            let chunk = (*remaining).min(zero_buf.len() as u64) as usize;
                            let fin = chunk as u64 == *remaining;
                            match conn.stream_send(stream_id, &zero_buf[..chunk], fin) {
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
                    streams.insert(stream_id, ServerStreamState::Done);
                }
            }

            // Clean up completed streams
            streams.retain(|_, s| !matches!(s, ServerStreamState::Done));

            // Flush outgoing packets
            flush_egress(conn, &socket, &"0.0.0.0:0".parse().unwrap());
        }
    }
}

// ---------------------------------------------------------------------------
// Client helpers
// ---------------------------------------------------------------------------

enum ClientTestType {
    Upload { bytes: u64 },
    Download { bytes: u64 },
    Latency,
}

fn run_client_test(
    server_addr: SocketAddr,
    test_type: ClientTestType,
) -> Result<Option<f64>, Box<dyn std::error::Error>> {
    let mut config = make_client_config();

    let mut poll = Poll::new()?;
    let mut socket = UdpSocket::bind("0.0.0.0:0".parse::<SocketAddr>()?)?;
    let local_addr = socket.local_addr()?;
    poll.registry().register(&mut socket, Token(0), Interest::READABLE)?;

    let scid = generate_scid();
    let mut conn = quiche::connect(Some("localhost"), &scid, local_addr, server_addr, &mut config)?;

    let mut recv_buf = [0u8; 65535];
    let mut events = Events::with_capacity(1024);

    // State machine
    enum Phase {
        Connecting,
        SendingHeader { stream_id: u64, header: [u8; 8], offset: usize },
        SendingUploadData { stream_id: u64, remaining: u64 },
        ReceivingDownload { stream_id: u64, expected: u64, received: u64 },
        Done,
    }

    let mut phase = Phase::Connecting;
    let start_time = Instant::now();
    let mut result: Option<f64> = None;

    // Initial flight
    flush_egress(&mut conn, &socket, &server_addr);

    loop {
        if conn.is_closed() {
            break;
        }

        let timeout = conn.timeout();
        poll.poll(&mut events, timeout)?;

        // Read incoming packets
        'read: loop {
            let (len, from) = match socket.recv_from(&mut recv_buf) {
                Ok(v) => v,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break 'read,
                Err(e) => return Err(e.into()),
            };

            let recv_info = quiche::RecvInfo {
                from,
                to: local_addr,
            };

            let _ = conn.recv(&mut recv_buf[..len], recv_info);
        }

        conn.on_timeout();

        // State transitions
        match &mut phase {
            Phase::Connecting => {
                if conn.is_established() {
                    let stream_id = 0u64; // Client-initiated bidi stream

                    let header = match &test_type {
                        ClientTestType::Upload { .. } => 0u64.to_be_bytes(),
                        ClientTestType::Download { bytes } => bytes.to_be_bytes(),
                        ClientTestType::Latency => 1u64.to_be_bytes(),
                    };

                    phase = Phase::SendingHeader {
                        stream_id,
                        header,
                        offset: 0,
                    };
                }
            }
            Phase::SendingHeader { stream_id, header, offset } => {
                let remaining_header = &header[*offset..];
                let fin_after_header = !matches!(test_type, ClientTestType::Upload { .. });
                let fin = fin_after_header;

                match conn.stream_send(*stream_id, remaining_header, fin) {
                    Ok(written) => {
                        *offset += written;
                        if *offset >= 8 {
                            let sid = *stream_id;
                            match &test_type {
                                ClientTestType::Upload { bytes } => {
                                    phase = Phase::SendingUploadData {
                                        stream_id: sid,
                                        remaining: *bytes,
                                    };
                                }
                                ClientTestType::Download { bytes } => {
                                    phase = Phase::ReceivingDownload {
                                        stream_id: sid,
                                        expected: *bytes,
                                        received: 0,
                                    };
                                }
                                ClientTestType::Latency => {
                                    phase = Phase::ReceivingDownload {
                                        stream_id: sid,
                                        expected: 1,
                                        received: 0,
                                    };
                                }
                            }
                        }
                    }
                    Err(quiche::Error::Done) => {}
                    Err(e) => {
                        eprintln!("stream_send header failed: {e}");
                        break;
                    }
                }
            }
            Phase::SendingUploadData { stream_id, remaining } => {
                let zero_buf = [0u8; 65535];
                while *remaining > 0 {
                    let chunk = (*remaining).min(zero_buf.len() as u64) as usize;
                    let fin = chunk as u64 == *remaining;
                    match conn.stream_send(*stream_id, &zero_buf[..chunk], fin) {
                        Ok(written) => *remaining -= written as u64,
                        Err(quiche::Error::Done) => break,
                        Err(e) => {
                            eprintln!("stream_send upload failed: {e}");
                            break;
                        }
                    }
                }
                if *remaining == 0 {
                    let elapsed = start_time.elapsed().as_secs_f64();
                    if let ClientTestType::Upload { bytes } = &test_type {
                        result = Some((*bytes as f64 * 8.0) / elapsed / 1e9);
                    }
                    let _ = conn.close(true, 0, b"");
                    phase = Phase::Done;
                }
            }
            Phase::ReceivingDownload { stream_id, expected, received } => {
                let mut buf = [0u8; 65535];
                loop {
                    match conn.stream_recv(*stream_id, &mut buf) {
                        Ok((len, fin)) => {
                            *received += len as u64;
                            if *received >= *expected || fin {
                                let elapsed = start_time.elapsed().as_secs_f64();
                                result = match &test_type {
                                    ClientTestType::Download { bytes } => {
                                        Some((*bytes as f64 * 8.0) / elapsed / 1e9)
                                    }
                                    ClientTestType::Latency => Some(elapsed * 1000.0),
                                    _ => None,
                                };
                                let _ = conn.close(true, 0, b"");
                                phase = Phase::Done;
                                break;
                            }
                        }
                        Err(quiche::Error::Done) => break,
                        Err(_) => break,
                    }
                }
            }
            Phase::Done => {
                // Wait for connection to close
            }
        }

        flush_egress(&mut conn, &socket, &server_addr);
    }

    Ok(result)
}

// ---------------------------------------------------------------------------
// Dialer
// ---------------------------------------------------------------------------

fn run_dialer(cfg: &AppConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("Running as dialer/client...");

    let key = format!("{}_listener_multiaddr", cfg.test_key);
    eprintln!("Waiting for listener address from Redis (key: {key})...");
    let multiaddr = redis_get_poll_blocking(&cfg.redis_addr, &key, 60)?;
    eprintln!("Got listener address: {multiaddr} (key: {key})");

    let server_addr = parse_multiaddr(&multiaddr)?;
    eprintln!("Connecting to QUIC server: {server_addr}");

    // Upload test
    eprintln!("Running upload test ({} iterations)...", cfg.upload_iters);
    let mut upload_values = Vec::with_capacity(cfg.upload_iters);
    for i in 0..cfg.upload_iters {
        match run_client_test(server_addr, ClientTestType::Upload { bytes: cfg.upload_bytes }) {
            Ok(Some(gbps)) => {
                upload_values.push(gbps);
                eprintln!("  Iteration {}/{}: {gbps:.2} Gbps", i + 1, cfg.upload_iters);
            }
            Ok(None) => eprintln!("Upload iteration {} no result", i + 1),
            Err(e) => eprintln!("Upload iteration {} failed: {e}", i + 1),
        }
    }
    let upload_stats = calculate_stats(&mut upload_values);

    // Download test
    eprintln!("Running download test ({} iterations)...", cfg.download_iters);
    let mut download_values = Vec::with_capacity(cfg.download_iters);
    for i in 0..cfg.download_iters {
        match run_client_test(server_addr, ClientTestType::Download { bytes: cfg.download_bytes }) {
            Ok(Some(gbps)) => {
                download_values.push(gbps);
                eprintln!("  Iteration {}/{}: {gbps:.2} Gbps", i + 1, cfg.download_iters);
            }
            Ok(None) => eprintln!("Download iteration {} no result", i + 1),
            Err(e) => eprintln!("Download iteration {} failed: {e}", i + 1),
        }
    }
    let download_stats = calculate_stats(&mut download_values);

    // Latency test
    eprintln!("Running latency test ({} iterations)...", cfg.latency_iters);
    let mut latency_values = Vec::with_capacity(cfg.latency_iters);
    for i in 0..cfg.latency_iters {
        match run_client_test(server_addr, ClientTestType::Latency) {
            Ok(Some(ms)) => latency_values.push(ms),
            Ok(None) => eprintln!("Latency iteration {} no result", i + 1),
            Err(e) => eprintln!("Latency iteration {} failed: {e}", i + 1),
        }
    }
    let latency_stats = calculate_stats(&mut latency_values);

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

fn main() {
    let cfg = AppConfig::from_env();

    let result = if cfg.is_dialer {
        run_dialer(&cfg)
    } else {
        run_listener(&cfg)
    };

    if let Err(e) = result {
        eprintln!("Fatal error: {e}");
        std::process::exit(1);
    }
}
