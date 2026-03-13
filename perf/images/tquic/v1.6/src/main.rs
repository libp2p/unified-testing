use std::collections::HashMap;
use std::env;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket as StdUdpSocket};
use std::cell::Cell;
use std::rc::Rc;
use std::time::Instant;

use bytes::Bytes;
use mio::net::UdpSocket;
use mio::{Events, Interest, Poll, Token};
use slab::Slab;
use tquic::{
    Config, Connection, Endpoint, PacketInfo, PacketSendHandler, TlsConfig, TransportHandler,
};

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
// Socket wrapper implementing PacketSendHandler
// ---------------------------------------------------------------------------

struct PerfSocket {
    socks: Slab<UdpSocket>,
    addrs: HashMap<SocketAddr, usize>,
    local_addr: SocketAddr,
}

impl PerfSocket {
    fn new(listen_addr: &SocketAddr, registry: &mio::Registry) -> std::io::Result<Self> {
        let mut socks = Slab::new();
        let mut addrs = HashMap::new();

        let socket = UdpSocket::bind(*listen_addr)?;
        let local_addr = socket.local_addr()?;
        let sid = socks.insert(socket);
        addrs.insert(local_addr, sid);

        let socket = socks.get_mut(sid).unwrap();
        registry.register(socket, Token(sid), Interest::READABLE)?;

        Ok(Self { socks, addrs, local_addr })
    }

    fn recv_from(&self, buf: &mut [u8], token: Token) -> std::io::Result<(usize, SocketAddr, SocketAddr)> {
        let socket = self.socks.get(token.0)
            .ok_or_else(|| std::io::Error::other("invalid token"))?;
        let (len, remote) = socket.recv_from(buf)?;
        Ok((len, socket.local_addr()?, remote))
    }
}

impl PacketSendHandler for PerfSocket {
    fn on_packets_send(&self, pkts: &[(Vec<u8>, PacketInfo)]) -> tquic::Result<usize> {
        let mut count = 0;
        for (pkt, info) in pkts {
            let sid = match self.addrs.get(&info.src) {
                Some(sid) => *sid,
                None => { count += 1; continue; }
            };
            let socket = match self.socks.get(sid) {
                Some(s) => s,
                None => { count += 1; continue; }
            };
            match socket.send_to(pkt, info.dst) {
                Ok(_) => count += 1,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => return Ok(count),
                Err(e) => return Err(tquic::Error::InvalidOperation(format!("send: {e}"))),
            }
        }
        Ok(count)
    }
}

// ---------------------------------------------------------------------------
// Server TransportHandler
// ---------------------------------------------------------------------------

enum ServerStreamState {
    ReadingHeader { buf: [u8; 8], offset: usize },
    DiscardingUpload,
    SendingDownload { remaining: u64 },
    Done,
}

struct ServerHandler {
    streams: HashMap<u64, HashMap<u64, ServerStreamState>>,
    buf: Vec<u8>,
}

impl ServerHandler {
    fn new() -> Self {
        Self {
            streams: HashMap::new(),
            buf: vec![0u8; 65535],
        }
    }

    fn handle_stream_read(&mut self, conn: &mut Connection, stream_id: u64) {
        let conn_idx = match conn.index() {
            Some(idx) => idx,
            None => return,
        };
        let conn_streams = self.streams.entry(conn_idx).or_default();
        conn_streams.entry(stream_id).or_insert_with(|| ServerStreamState::ReadingHeader {
            buf: [0u8; 8],
            offset: 0,
        });

        loop {
            let state = conn_streams.get_mut(&stream_id).unwrap();
            match state {
                ServerStreamState::ReadingHeader { buf, offset } => {
                    match conn.stream_read(stream_id, &mut self.buf) {
                        Ok((len, fin)) => {
                            let need = 8 - *offset;
                            let copy_len = len.min(need);
                            buf[*offset..*offset + copy_len].copy_from_slice(&self.buf[..copy_len]);
                            *offset += copy_len;

                            if *offset >= 8 {
                                let requested = u64::from_be_bytes(*buf);
                                if requested == 0 {
                                    *state = ServerStreamState::DiscardingUpload;
                                } else {
                                    *state = ServerStreamState::SendingDownload { remaining: requested };
                                    // Trigger writes
                                    let _ = conn.stream_want_write(stream_id, true);
                                }
                            } else if fin {
                                *state = ServerStreamState::Done;
                                return;
                            } else {
                                return;
                            }
                        }
                        Err(_) => return,
                    }
                }
                ServerStreamState::DiscardingUpload => {
                    match conn.stream_read(stream_id, &mut self.buf) {
                        Ok((_len, fin)) => {
                            if fin {
                                *state = ServerStreamState::Done;
                                return;
                            }
                        }
                        Err(_) => return,
                    }
                }
                _ => return,
            }
        }
    }

    fn handle_stream_write(&mut self, conn: &mut Connection, stream_id: u64) {
        let conn_idx = match conn.index() {
            Some(idx) => idx,
            None => return,
        };
        let conn_streams = match self.streams.get_mut(&conn_idx) {
            Some(s) => s,
            None => return,
        };
        let state = match conn_streams.get_mut(&stream_id) {
            Some(s) => s,
            None => return,
        };

        let mark_done = if let ServerStreamState::SendingDownload { remaining } = state {
            let zero_buf = vec![0u8; 65535];
            let mut done = false;
            while *remaining > 0 {
                let chunk = (*remaining).min(zero_buf.len() as u64) as usize;
                let fin = chunk as u64 == *remaining;
                match conn.stream_write(stream_id, Bytes::copy_from_slice(&zero_buf[..chunk]), fin) {
                    Ok(written) => {
                        *remaining -= written as u64;
                        if *remaining == 0 {
                            done = true;
                        }
                    }
                    Err(_) => {
                        let _ = conn.stream_want_write(stream_id, true);
                        return;
                    }
                }
            }
            done
        } else {
            false
        };
        if mark_done {
            *state = ServerStreamState::Done;
        }
    }
}

impl TransportHandler for ServerHandler {
    fn on_conn_created(&mut self, _conn: &mut Connection) {}
    fn on_conn_established(&mut self, _conn: &mut Connection) {}

    fn on_conn_closed(&mut self, conn: &mut Connection) {
        if let Some(idx) = conn.index() {
            self.streams.remove(&idx);
        }
    }

    fn on_stream_created(&mut self, _conn: &mut Connection, _stream_id: u64) {}

    fn on_stream_readable(&mut self, conn: &mut Connection, stream_id: u64) {
        self.handle_stream_read(conn, stream_id);
    }

    fn on_stream_writable(&mut self, conn: &mut Connection, stream_id: u64) {
        self.handle_stream_write(conn, stream_id);
    }

    fn on_stream_closed(&mut self, _conn: &mut Connection, _stream_id: u64) {}
    fn on_new_token(&mut self, _conn: &mut Connection, _token: Vec<u8>) {}
}

// ---------------------------------------------------------------------------
// Client TransportHandler
// ---------------------------------------------------------------------------

enum ClientPhase {
    WaitingForConn,
    SendingHeader { stream_id: u64, header: [u8; 8], offset: usize },
    SendingUploadData { stream_id: u64, remaining: u64 },
    ReceivingDownload { stream_id: u64, expected: u64, received: u64 },
    Done,
}

struct ClientHandler {
    test_type: ClientTestType,
    phase: ClientPhase,
    start_time: Option<Instant>,
    result: Option<f64>,
    done: bool,
    buf: Vec<u8>,
    signal: Rc<ClientDoneSignal>,
}

enum ClientTestType {
    Upload { bytes: u64 },
    Download { bytes: u64 },
    Latency,
}

/// Shared completion signal between ClientHandler and the event loop caller.
/// Uses Rc<Cell<>> since tquic types are !Send and everything runs on one thread.
struct ClientDoneSignal {
    done: Cell<bool>,
    result: Cell<Option<f64>>,
}

impl ClientHandler {
    fn new(test_type: ClientTestType, signal: Rc<ClientDoneSignal>) -> Self {
        Self {
            test_type,
            phase: ClientPhase::WaitingForConn,
            start_time: None,
            result: None,
            done: false,
            buf: vec![0u8; 65535],
            signal,
        }
    }

    fn mark_done(&mut self, result: Option<f64>) {
        self.done = true;
        self.result = result;
        self.signal.done.set(true);
        self.signal.result.set(result);
    }

    fn start_test(&mut self, conn: &mut Connection) {
        self.start_time = Some(Instant::now());

        let stream_id = match conn.stream_bidi_new(0, false) {
            Ok(id) => id,
            Err(e) => {
                eprintln!("Failed to create stream: {e}");
                self.mark_done(None);
                return;
            }
        };

        let header = match &self.test_type {
            ClientTestType::Upload { .. } => 0u64.to_be_bytes(),
            ClientTestType::Download { bytes } => bytes.to_be_bytes(),
            ClientTestType::Latency => 1u64.to_be_bytes(),
        };

        self.phase = ClientPhase::SendingHeader {
            stream_id,
            header,
            offset: 0,
        };

        // Trigger writable callback
        let _ = conn.stream_want_write(stream_id, true);
    }

    fn handle_write(&mut self, conn: &mut Connection, stream_id: u64) {
        loop {
            match &mut self.phase {
                ClientPhase::SendingHeader { stream_id: sid, header, offset } if *sid == stream_id => {
                    let remaining = &header[*offset..];
                    let fin_header = !matches!(self.test_type, ClientTestType::Upload { .. });
                    let fin = fin_header;
                    match conn.stream_write(stream_id, Bytes::copy_from_slice(remaining), fin) {
                        Ok(written) => {
                            *offset += written;
                            if *offset >= 8 {
                                match &self.test_type {
                                    ClientTestType::Upload { bytes } => {
                                        self.phase = ClientPhase::SendingUploadData {
                                            stream_id,
                                            remaining: *bytes,
                                        };
                                    }
                                    ClientTestType::Download { bytes } => {
                                        self.phase = ClientPhase::ReceivingDownload {
                                            stream_id,
                                            expected: *bytes,
                                            received: 0,
                                        };
                                        return;
                                    }
                                    ClientTestType::Latency => {
                                        self.phase = ClientPhase::ReceivingDownload {
                                            stream_id,
                                            expected: 1,
                                            received: 0,
                                        };
                                        return;
                                    }
                                }
                            } else {
                                let _ = conn.stream_want_write(stream_id, true);
                                return;
                            }
                        }
                        Err(_) => {
                            let _ = conn.stream_want_write(stream_id, true);
                            return;
                        }
                    }
                }
                ClientPhase::SendingUploadData { stream_id: sid, remaining } if *sid == stream_id => {
                    let zero_buf = [0u8; 65535];
                    while *remaining > 0 {
                        let chunk = (*remaining).min(zero_buf.len() as u64) as usize;
                        let fin = chunk as u64 == *remaining;
                        match conn.stream_write(stream_id, Bytes::copy_from_slice(&zero_buf[..chunk]), fin) {
                            Ok(written) => *remaining -= written as u64,
                            Err(_) => {
                                let _ = conn.stream_want_write(stream_id, true);
                                return;
                            }
                        }
                    }
                    // Upload complete
                    let elapsed = self.start_time.unwrap().elapsed().as_secs_f64();
                    let result = if let ClientTestType::Upload { bytes } = &self.test_type {
                        Some((*bytes as f64 * 8.0) / elapsed / 1e9)
                    } else {
                        None
                    };
                    self.mark_done(result);
                    self.phase = ClientPhase::Done;
                    let _ = conn.close(true, 0, b"");
                    return;
                }
                _ => return,
            }
        }
    }

    fn handle_read(&mut self, conn: &mut Connection, stream_id: u64) {
        if let ClientPhase::ReceivingDownload { stream_id: sid, expected, received } = &mut self.phase {
            if *sid != stream_id { return; }
            loop {
                match conn.stream_read(stream_id, &mut self.buf) {
                    Ok((len, fin)) => {
                        *received += len as u64;
                        if *received >= *expected || fin {
                            let elapsed = self.start_time.unwrap().elapsed().as_secs_f64();
                            let result = match &self.test_type {
                                ClientTestType::Download { bytes } => {
                                    (*bytes as f64 * 8.0) / elapsed / 1e9
                                }
                                ClientTestType::Latency => elapsed * 1000.0,
                                _ => 0.0,
                            };
                            self.mark_done(Some(result));
                            self.phase = ClientPhase::Done;
                            let _ = conn.close(true, 0, b"");
                            return;
                        }
                    }
                    Err(_) => return,
                }
            }
        }
    }
}

impl TransportHandler for ClientHandler {
    fn on_conn_created(&mut self, _conn: &mut Connection) {}

    fn on_conn_established(&mut self, conn: &mut Connection) {
        self.start_test(conn);
    }

    fn on_conn_closed(&mut self, _conn: &mut Connection) {
        self.mark_done(self.result);
    }

    fn on_stream_created(&mut self, _conn: &mut Connection, _stream_id: u64) {}

    fn on_stream_readable(&mut self, conn: &mut Connection, stream_id: u64) {
        self.handle_read(conn, stream_id);
    }

    fn on_stream_writable(&mut self, conn: &mut Connection, stream_id: u64) {
        self.handle_write(conn, stream_id);
    }

    fn on_stream_closed(&mut self, _conn: &mut Connection, _stream_id: u64) {}
    fn on_new_token(&mut self, _conn: &mut Connection, _token: Vec<u8>) {}
}

// ---------------------------------------------------------------------------
// Listener
// ---------------------------------------------------------------------------

fn run_listener(cfg: &AppConfig) -> Result<(), Box<dyn std::error::Error>> {
    let tls_files = generate_tls_cert_files();

    let mut config = Config::new()?;
    let tls_config = TlsConfig::new_server_config(
        &tls_files.cert_path,
        &tls_files.key_path,
        vec![b"perf".to_vec()],
        false,
    )?;
    config.set_tls_config(tls_config);
    config.set_max_idle_timeout(30_000); // 30 seconds in ms
    config.set_recv_udp_payload_size(65535);

    let poll = Poll::new()?;
    let registry = poll.registry();
    let sock = Rc::new(PerfSocket::new(&"0.0.0.0:4001".parse()?, registry)?);

    let handler = ServerHandler::new();
    let mut endpoint = Endpoint::new(
        Box::new(config),
        true,
        Box::new(handler),
        sock.clone(),
    );

    let container_ip = get_container_ip();
    eprintln!("Detected container IP: {container_ip}");

    let multiaddr = format!("/ip4/{container_ip}/udp/4001/quic-v1");
    eprintln!("Publishing listener address to Redis: {multiaddr}");

    let key = format!("{}_listener_multiaddr", cfg.test_key);
    redis_set_blocking(&cfg.redis_addr, &key, &multiaddr)?;
    eprintln!("Published to Redis (key: {key})");
    eprintln!("QUIC listener ready");

    let mut recv_buf = vec![0u8; 65535];
    let mut events = Events::with_capacity(1024);
    let mut poll = poll;

    loop {
        if let Err(e) = endpoint.process_connections() {
            eprintln!("process_connections error: {e}");
        }

        let timeout = endpoint.timeout();
        poll.poll(&mut events, timeout)?;

        for event in events.iter() {
            if event.is_readable() {
                loop {
                    match sock.recv_from(&mut recv_buf, event.token()) {
                        Ok((len, local, remote)) => {
                            let pkt_info = PacketInfo {
                                src: remote,
                                dst: local,
                                time: Instant::now(),
                            };
                            let _ = endpoint.recv(&mut recv_buf[..len], &pkt_info);
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(e) => return Err(e.into()),
                    }
                }
            }
        }

        endpoint.on_timeout(Instant::now());
    }
}

// ---------------------------------------------------------------------------
// Dialer
// ---------------------------------------------------------------------------

fn run_client_test(
    server_addr: SocketAddr,
    _tls_files: &TlsCertFiles,
    test_type: ClientTestType,
) -> Result<Option<f64>, Box<dyn std::error::Error>> {
    let mut config = Config::new()?;
    let tls_config = TlsConfig::new_client_config(vec![b"perf".to_vec()], false)?;
    config.set_tls_config(tls_config);
    config.set_max_idle_timeout(30_000);
    config.set_recv_udp_payload_size(65535);

    let poll = Poll::new()?;
    let registry = poll.registry();
    let sock = Rc::new(PerfSocket::new(&"0.0.0.0:0".parse()?, registry)?);

    let signal = Rc::new(ClientDoneSignal {
        done: Cell::new(false),
        result: Cell::new(None),
    });
    let handler = ClientHandler::new(test_type, signal.clone());

    let mut endpoint = Endpoint::new(
        Box::new(config),
        false, // client mode
        Box::new(handler),
        sock.clone(),
    );

    // Initiate connection
    endpoint.connect(
        sock.local_addr,
        server_addr,
        Some("localhost"),
        None,
        None,
        None,
    )?;

    let mut recv_buf = vec![0u8; 65535];
    let mut events = Events::with_capacity(1024);
    let mut poll = poll;

    loop {
        endpoint.process_connections()?;

        // Check completion via shared signal (safe, no raw pointers)
        if signal.done.get() {
            return Ok(signal.result.get());
        }

        let timeout = endpoint.timeout();
        poll.poll(&mut events, timeout)?;

        for event in events.iter() {
            if event.is_readable() {
                loop {
                    match sock.recv_from(&mut recv_buf, event.token()) {
                        Ok((len, local, remote)) => {
                            let pkt_info = PacketInfo {
                                src: remote,
                                dst: local,
                                time: Instant::now(),
                            };
                            let _ = endpoint.recv(&mut recv_buf[..len], &pkt_info);
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(e) => return Err(e.into()),
                    }
                }
            }
        }

        endpoint.on_timeout(Instant::now());
    }
}

fn run_dialer(cfg: &AppConfig) -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("Running as dialer/client...");

    let tls_files = generate_tls_cert_files();

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
        match run_client_test(server_addr, &tls_files, ClientTestType::Upload { bytes: cfg.upload_bytes }) {
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
        match run_client_test(server_addr, &tls_files, ClientTestType::Download { bytes: cfg.download_bytes }) {
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
        match run_client_test(server_addr, &tls_files, ClientTestType::Latency) {
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
