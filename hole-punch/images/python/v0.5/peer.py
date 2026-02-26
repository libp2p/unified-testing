#!/usr/bin/env python3
"""
py-libp2p hole-punch test peer implementation.
Handles both dialer and listener roles for DCUtR interop testing.
"""

import logging
import os
import sys
import time

import multiaddr
import redis
import trio

from libp2p import new_host, create_yamux_muxer_option, create_mplex_muxer_option
from libp2p.crypto.ed25519 import create_new_key_pair
from libp2p.crypto.x25519 import create_new_key_pair as create_new_x25519_key_pair
from libp2p.peer.peerinfo import info_from_p2p_addr, PeerInfo
from libp2p.peer.id import ID
from libp2p.relay.circuit_v2.dcutr import DCUtRProtocol
from libp2p.relay.circuit_v2.protocol import CircuitV2Protocol, DEFAULT_RELAY_LIMITS
from libp2p.relay.circuit_v2.config import RelayConfig, RelayRole
import libp2p.relay.circuit_v2.transport as _circuit_transport_mod
from libp2p.relay.circuit_v2.transport import CircuitV2Transport
from libp2p.security.noise.transport import (
    PROTOCOL_ID as NOISE_PROTOCOL_ID,
    Transport as NoiseTransport,
)
from libp2p.security.tls.transport import (
    PROTOCOL_ID as TLS_PROTOCOL_ID,
    TLSTransport,
)
from libp2p.tools.async_service import background_trio_service
from libp2p.network.connection.raw_connection import RawConnection

logger = logging.getLogger("hole-punch-peer")

# --- Rust relay wire compatibility (length-delimited framing + rust-libp2p proto layout) ---
# When RELAY_ID is Rust we use varint(length) + message and Rust's HopMessage/Reservation/Status.

# HopMessage type (rust-libp2p): RESERVE=0, CONNECT=1, STATUS=2
# Status enum: OK=100
RUST_STATUS_OK = 100


def _varint_encode(n: int) -> bytes:
    """Encode non-negative int as unsigned varint (same as quick-protobuf-codec)."""
    if n < 0:
        raise ValueError("varint must be non-negative")
    buf = []
    while n > 0x7F:
        buf.append((n & 0x7F) | 0x80)
        n >>= 7
    buf.append(n & 0x7F)
    return bytes(buf)


def _varint_decode(buf: bytes, start: int = 0) -> tuple[int, int]:
    """Decode unsigned varint from buf starting at start. Returns (value, bytes_consumed)."""
    n = 0
    shift = 0
    i = start
    while i < len(buf):
        b = buf[i]
        n |= (b & 0x7F) << shift
        i += 1
        if (b & 0x80) == 0:
            return n, i - start
        shift += 7
        if shift >= 64:
            raise ValueError("varint too long")
    raise ValueError("varint truncated")


def _encode_rust_reserve_request() -> bytes:
    """Minimal RESERVE HopMessage (type=0 only)."""
    # field 1, wire type 0 (varint), value 0
    return b"\x08\x00"


def _encode_rust_connect_request(peer_id_bytes: bytes) -> bytes:
    """CONNECT HopMessage: type=1, peer=Peer{id=peer_id_bytes, addrs=[]}.
    Rust proto: peer is message Peer { required bytes id=1; repeated bytes addrs=2; }."""
    # Peer message: field 1 (id): tag 0x0a, length, bytes
    peer_inner = b"\x0a" + _varint_encode(len(peer_id_bytes)) + peer_id_bytes
    # HopMessage: field 1 (type)=CONNECT, field 2 (peer)=Peer message
    peer_outer_len = _varint_encode(len(peer_inner))
    return b"\x08\x01\x12" + peer_outer_len + peer_inner


def _parse_rust_hop_message(buf: bytes) -> dict:
    """
    Parse Rust-shaped HopMessage from buf. Returns dict with:
    type_pb (int), status (int | None), reservation (dict | None with expire, addrs).
    """
    out = {"type_pb": None, "status": None, "reservation": None}
    i = 0
    while i < len(buf):
        if i >= len(buf):
            break
        tag = buf[i]
        i += 1
        if i >= len(buf):
            break
        field_num = tag >> 3
        wire = tag & 7
        if wire == 0:  # varint
            n, consumed = _varint_decode(buf, i)
            i += consumed
            if field_num == 1:
                out["type_pb"] = n
            elif field_num == 5:
                out["status"] = n
        elif wire == 2:  # length-delimited
            length, consumed = _varint_decode(buf, i)
            i += consumed
            end = i + length
            if end > len(buf):
                break
            chunk = buf[i:end]
            i = end
            if field_num == 3:  # reservation message
                out["reservation"] = _parse_rust_reservation(chunk)
            # field 2 (peer) we ignore
    return out


# Rust StopMessage: type (1), peer (2, Peer msg), limit (3), status (4). CONNECT=0, STATUS=1.
def _parse_rust_stop_message(buf: bytes) -> dict:
    """Parse Rust StopMessage; return dict with type_pb, peer_id (bytes or None)."""
    out = {"type_pb": None, "peer_id": None}
    i = 0
    while i < len(buf):
        if i >= len(buf):
            break
        tag = buf[i]
        i += 1
        if i >= len(buf):
            break
        field_num = tag >> 3
        wire = tag & 7
        if wire == 0:  # varint
            n, consumed = _varint_decode(buf, i)
            i += consumed
            if field_num == 1:
                out["type_pb"] = n
            # field 4 status we don't need when parsing CONNECT
        elif wire == 2:  # length-delimited
            length, consumed = _varint_decode(buf, i)
            i += consumed
            end = i + length
            if end > len(buf):
                break
            if field_num == 2:  # Peer message: field 1 = id (bytes)
                chunk = buf[i:end]
                pi = 0
                while pi < len(chunk):
                    if pi >= len(chunk):
                        break
                    pt = chunk[pi]
                    pi += 1
                    if pi >= len(chunk):
                        break
                    pfn = pt >> 3
                    pw = pt & 7
                    if pw == 2 and pfn == 1:  # id = field 1, length-delimited
                        plen, pc = _varint_decode(chunk, pi)
                        pi += pc
                        if pi + plen <= len(chunk):
                            out["peer_id"] = bytes(chunk[pi : pi + plen])
                        break
                    elif pw == 0:
                        _, pc = _varint_decode(chunk, pi)
                        pi += pc
                    elif pw == 2:
                        plen, pc = _varint_decode(chunk, pi)
                        pi += pc + plen
                break
            i = end
    return out


def _encode_rust_stop_status_ok() -> bytes:
    """Rust StopMessage STATUS with status=100 (OK). type=1 (STATUS), status=100."""
    return b"\x08\x01\x20\x64"  # field 1 (type)=1, field 4 (status)=100


def _encode_rust_stop_status_error(status_code: int) -> bytes:
    """Rust StopMessage STATUS with given status (e.g. 400 MALFORMED_MESSAGE)."""
    # type=1 (STATUS), field 4 = varint status_code
    return b"\x08\x01\x20" + _varint_encode(status_code)


def _parse_rust_reservation(buf: bytes) -> dict:
    """Parse Rust Reservation: expire (1), addrs (2 repeated)."""
    out = {"expire": None, "addrs": []}
    i = 0
    while i < len(buf):
        if i >= len(buf):
            break
        tag = buf[i]
        i += 1
        if i >= len(buf):
            break
        field_num = tag >> 3
        wire = tag & 7
        if wire == 0:
            n, consumed = _varint_decode(buf, i)
            i += consumed
            if field_num == 1:
                out["expire"] = n
        elif wire == 2:
            length, consumed = _varint_decode(buf, i)
            i += consumed
            end = i + length
            if end > len(buf):
                break
            if field_num == 2:
                out["addrs"].append(buf[i:end])
            i = end
    return out


async def _read_varint_prefixed_message(stream) -> bytes:
    """Read unsigned_varint(length) then exactly length bytes from stream."""
    chunks = []
    total = 0
    while True:
        chunk = await stream.read(1)
        if not chunk:
            raise ValueError("varint truncated")
        chunks.append(chunk)
        total += 1
        if total > 10:
            raise ValueError("varint too long")
        if (chunk[0] & 0x80) == 0:
            break
    buf = b"".join(chunks)
    length, _ = _varint_decode(buf, 0)
    payload = b""
    while len(payload) < length:
        got = await stream.read(length - len(payload))
        if not got:
            raise ValueError("message truncated")
        payload += got
    return payload


async def _write_varint_prefixed_message(stream, message: bytes) -> None:
    """Write unsigned_varint(len(message)) then message to stream."""
    prefix = _varint_encode(len(message))
    await stream.write(prefix + message)


class HolePunchPeer:
    def __init__(self):
        # Required environment variables
        self.is_dialer = os.getenv("IS_DIALER", "false").lower() == "true"
        self.redis_addr = os.getenv("REDIS_ADDR")
        self.test_key = os.getenv("TEST_KEY")
        self.relay_id = os.getenv("RELAY_ID", "")
        self.transport = os.getenv("TRANSPORT", "tcp")
        self.secure_channel = os.getenv("SECURE_CHANNEL")  # May be None for QUIC
        self.muxer = os.getenv("MUXER")  # May be None for QUIC
        self.peer_ip = os.getenv("PEER_IP", "0.0.0.0")
        self.router_ip = os.getenv("ROUTER_IP")
        self.debug = os.getenv("DEBUG", "false").lower() == "true"

        # Validate required env vars
        if not self.redis_addr:
            raise ValueError("REDIS_ADDR environment variable is required")
        if not self.test_key:
            raise ValueError("TEST_KEY environment variable is required")

        # Parse Redis address
        if ":" in self.redis_addr:
            host, port = self.redis_addr.split(":")
            self.redis_host, self.redis_port = host, int(port)
        else:
            self.redis_host = self.redis_addr
            self.redis_port = 6379

        self.redis_client = None
        self.host = None

    def create_security_options(self):
        """Create security transport options based on SECURE_CHANNEL."""
        key_pair = create_new_key_pair()

        # Standalone transports (QUIC) have built-in security
        if self.transport == "quic-v1":
            return {}, key_pair

        if self.secure_channel == "noise":
            noise_key_pair = create_new_x25519_key_pair()
            noise_transport = NoiseTransport(
                libp2p_keypair=key_pair,
                noise_privkey=noise_key_pair.private_key,
                early_data=None,
            )
            return {NOISE_PROTOCOL_ID: noise_transport}, key_pair
        elif self.secure_channel == "tls":
            tls_transport = TLSTransport(
                libp2p_keypair=key_pair,
                early_data=None,
                muxers=None,
            )
            return {TLS_PROTOCOL_ID: tls_transport}, key_pair
        else:
            raise ValueError(f"Unsupported secure channel: {self.secure_channel}")

    def create_muxer_options(self):
        """Create muxer options based on MUXER."""
        if self.transport == "quic-v1":
            return None  # QUIC has built-in muxing

        if self.muxer == "yamux":
            return create_yamux_muxer_option()
        elif self.muxer == "mplex":
            return create_mplex_muxer_option()
        else:
            raise ValueError(f"Unsupported muxer: {self.muxer}")

    def create_listen_address(self, port: int = 0):
        """Create listen multiaddr based on transport."""
        if self.transport == "tcp":
            return multiaddr.Multiaddr(f"/ip4/{self.peer_ip}/tcp/{port}")
        elif self.transport == "quic-v1":
            return multiaddr.Multiaddr(f"/ip4/{self.peer_ip}/udp/{port}/quic-v1")
        elif self.transport == "ws":
            return multiaddr.Multiaddr(f"/ip4/{self.peer_ip}/tcp/{port}/ws")
        elif self.transport == "wss":
            return multiaddr.Multiaddr(f"/ip4/{self.peer_ip}/tcp/{port}/wss")
        else:
            raise ValueError(f"Unsupported transport: {self.transport}")

    async def connect_redis(self):
        """Connect to Redis with retry."""
        print(f"Connecting to Redis at {self.redis_host}:{self.redis_port}...", file=sys.stderr)
        for attempt in range(10):
            try:
                self.redis_client = redis.Redis(
                    host=self.redis_host,
                    port=self.redis_port,
                    decode_responses=True
                )
                self.redis_client.ping()
                print(f"Connected to Redis on attempt {attempt + 1}", file=sys.stderr)
                return
            except Exception as e:
                print(f"Redis connection attempt {attempt + 1} failed: {e}", file=sys.stderr)
                if attempt < 9:
                    await trio.sleep(1)
        raise RuntimeError("Failed to connect to Redis after 10 attempts")

    async def run_listener(self):
        """Run as listener (IS_DIALER=false)."""
        print("Starting as LISTENER...", file=sys.stderr)
        print(f"  TRANSPORT: {self.transport}", file=sys.stderr)
        print(f"  SECURE_CHANNEL: {self.secure_channel}", file=sys.stderr)
        print(f"  MUXER: {self.muxer}", file=sys.stderr)
        print(f"  PEER_IP: {self.peer_ip}", file=sys.stderr)

        sec_opt, key_pair = self.create_security_options()
        muxer_opt = self.create_muxer_options()
        listen_addr = self.create_listen_address(4001)

        self.host = new_host(
            key_pair=key_pair,
            sec_opt=sec_opt,
            muxer_opt=muxer_opt,
            enable_quic=(self.transport == "quic-v1"),
            listen_addrs=[listen_addr],
        )

        # Configure relay client
        relay_config = RelayConfig(
            roles=RelayRole.STOP | RelayRole.CLIENT,
        )
        relay_protocol = CircuitV2Protocol(self.host, DEFAULT_RELAY_LIMITS, allow_hop=False)
        dcutr_protocol = DCUtRProtocol(self.host)

        async with self.host.run(listen_addrs=[listen_addr]):
            async with background_trio_service(relay_protocol):
                async with background_trio_service(dcutr_protocol):
                    await relay_protocol.event_started.wait()
                    await dcutr_protocol.event_started.wait()

                    if self._is_rust_relay():
                        self.host.set_stream_handler(
                            "/libp2p/circuit/relay/0.2.0/stop",
                            lambda s: self._handle_rust_stop_stream(s, relay_protocol),
                        )

                    # Initialize transport
                    transport = CircuitV2Transport(self.host, relay_protocol, relay_config)

                    peer_id = str(self.host.get_id())
                    print(f"Listener peer ID: {peer_id}", file=sys.stderr)

                    # Wait for relay multiaddr
                    relay_key = f"{self.test_key}_relay_multiaddr"
                    relay_addr = None
                    print(f"Waiting for relay multiaddr at key: {relay_key}", file=sys.stderr)
                    for i in range(60):  # 60 second timeout
                        relay_addr = self.redis_client.get(relay_key)
                        if relay_addr:
                            break
                        if i % 10 == 0:
                            print(f"  Still waiting for relay... ({i}s)", file=sys.stderr)
                        await trio.sleep(1)

                    if not relay_addr:
                        raise RuntimeError("Timeout waiting for relay multiaddr")

                    print(f"Got relay multiaddr: {relay_addr}", file=sys.stderr)

                    # Connect to relay
                    relay_maddr = multiaddr.Multiaddr(relay_addr)
                    relay_info = info_from_p2p_addr(relay_maddr)
                    await self.host.connect(relay_info)
                    print(f"Connected to relay: {relay_info.peer_id}", file=sys.stderr)

                    # Add relay to peerstore for circuit reservation
                    self.host.get_peerstore().add_addrs(
                        relay_info.peer_id, relay_info.addrs, 3600
                    )

                    # Make relay reservation BEFORE publishing peer_id.
                    # rust-libp2p relay requires an explicit RESERVE before it will
                    # forward CONNECT messages to this peer. py relay accepts it too.
                    print("Making relay reservation...", file=sys.stderr)
                    try:
                        hop_stream = await self.host.new_stream(
                            relay_info.peer_id, [_circuit_transport_mod.PROTOCOL_ID]
                        )
                        if self._is_rust_relay():
                            reserved = await self._make_reservation_rust_relay(
                                hop_stream, relay_info.peer_id
                            )
                        else:
                            reserved = await transport._make_reservation(
                                hop_stream, relay_info.peer_id
                            )
                        print(
                            f"Relay reservation: {'OK' if reserved else 'FAILED'}",
                            file=sys.stderr,
                        )
                        try:
                            await hop_stream.close()
                        except Exception:
                            pass
                    except Exception as e:
                        print(
                            f"Warning: Could not make relay reservation: {e}",
                            file=sys.stderr,
                        )

                    # Publish our peer ID to Redis only AFTER reserving so the dialer
                    # can be sure the relay is ready to forward traffic to us.
                    redis_key = f"{self.test_key}_listener_peer_id"
                    self.redis_client.set(redis_key, peer_id)
                    print(f"Published peer ID to Redis key: {redis_key}", file=sys.stderr)

                    # Wait for DCUtR to complete (dialer will initiate)
                    # The listener just needs to stay alive and respond
                    print("Listener ready, waiting for hole punch...", file=sys.stderr)

                    # Run forever until container is shut down
                    await trio.sleep_forever()

    async def run_dialer(self):
        """Run as dialer (IS_DIALER=true)."""
        print("Starting as DIALER...", file=sys.stderr)
        print(f"  TRANSPORT: {self.transport}", file=sys.stderr)
        print(f"  SECURE_CHANNEL: {self.secure_channel}", file=sys.stderr)
        print(f"  MUXER: {self.muxer}", file=sys.stderr)
        print(f"  PEER_IP: {self.peer_ip}", file=sys.stderr)

        sec_opt, key_pair = self.create_security_options()
        muxer_opt = self.create_muxer_options()
        listen_addr = self.create_listen_address(4001)

        self.host = new_host(
            key_pair=key_pair,
            sec_opt=sec_opt,
            muxer_opt=muxer_opt,
            enable_quic=(self.transport == "quic-v1"),
            listen_addrs=[listen_addr],
        )

        # Configure relay client.
        # CLIENT enabled: the transport sends RESERVE then CONNECT on the same HOP stream.
        # When RELAY_ID is rust, we use Rust protocol ID /libp2p/circuit/relay/2.0.0/hop
        # (set in _use_rust_relay_protocol_id_if_needed) so py peers can talk to Rust relay.
        relay_config = RelayConfig(
            roles=RelayRole.STOP | RelayRole.CLIENT,
        )
        relay_protocol = CircuitV2Protocol(self.host, DEFAULT_RELAY_LIMITS, allow_hop=False)
        dcutr_protocol = DCUtRProtocol(self.host)

        async with self.host.run(listen_addrs=[listen_addr]):
            async with background_trio_service(relay_protocol):
                async with background_trio_service(dcutr_protocol):
                    await relay_protocol.event_started.wait()
                    await dcutr_protocol.event_started.wait()

                    # Initialize transport
                    transport = CircuitV2Transport(self.host, relay_protocol, relay_config)

                    peer_id = str(self.host.get_id())
                    print(f"Dialer peer ID: {peer_id}", file=sys.stderr)

                    # Wait for relay multiaddr
                    relay_key = f"{self.test_key}_relay_multiaddr"
                    relay_addr = None
                    print(f"Waiting for relay multiaddr at key: {relay_key}", file=sys.stderr)
                    for i in range(60):
                        relay_addr = self.redis_client.get(relay_key)
                        if relay_addr:
                            break
                        if i % 10 == 0:
                            print(f"  Still waiting for relay... ({i}s)", file=sys.stderr)
                        await trio.sleep(1)

                    if not relay_addr:
                        raise RuntimeError("Timeout waiting for relay multiaddr")

                    print(f"Got relay multiaddr: {relay_addr}", file=sys.stderr)

                    # Connect to relay
                    relay_maddr = multiaddr.Multiaddr(relay_addr)
                    relay_info = info_from_p2p_addr(relay_maddr)
                    await self.host.connect(relay_info)
                    print(f"Connected to relay: {relay_info.peer_id}", file=sys.stderr)

                    # Wait for listener peer ID
                    listener_key = f"{self.test_key}_listener_peer_id"
                    listener_peer_id_str = None
                    print(f"Waiting for listener peer ID at key: {listener_key}", file=sys.stderr)
                    for i in range(60):
                        listener_peer_id_str = self.redis_client.get(listener_key)
                        if listener_peer_id_str:
                            break
                        if i % 10 == 0:
                            print(f"  Still waiting for listener... ({i}s)", file=sys.stderr)
                        await trio.sleep(1)

                    if not listener_peer_id_str:
                        raise RuntimeError("Timeout waiting for listener peer ID")

                    print(f"Got listener peer ID: {listener_peer_id_str}", file=sys.stderr)
                    listener_peer_id = ID.from_base58(listener_peer_id_str)

                    # Create circuit address to listener through relay
                    circuit_addr = multiaddr.Multiaddr(
                        f"{relay_addr}/p2p-circuit/p2p/{listener_peer_id_str}"
                    )
                    print(f"Circuit address: {circuit_addr}", file=sys.stderr)

                    # Start timing for DCUtR
                    handshake_start = time.time()

                    # Connect through relay using the circuit transport
                    print("Connecting to listener through relay...", file=sys.stderr)

                    if self._is_rust_relay():
                        self.host.get_peerstore().add_addrs(listener_peer_id, [circuit_addr], 3600)
                        stream = await self._dial_rust_relay(
                            transport, relay_info, listener_peer_id
                        )
                        if stream:
                            raw_conn = RawConnection(stream=stream, initiator=True)
                            await self.host.upgrade_outbound_connection(
                                raw_conn, listener_peer_id
                            )
                    else:
                        await transport.dial(circuit_addr)
                    print("Connected to listener through relay", file=sys.stderr)

                    # Initiate hole punch
                    print("Initiating hole punch...", file=sys.stderr)
                    result = await dcutr_protocol.initiate_hole_punch(listener_peer_id)

                    handshake_end = time.time()
                    handshake_time_ms = (handshake_end - handshake_start) * 1000

                    # Verify direct connection
                    has_direct = await dcutr_protocol._have_direct_connection(listener_peer_id)

                    print(f"Hole punch result: {result}", file=sys.stderr)
                    print(f"Has direct connection: {has_direct}", file=sys.stderr)

                    if has_direct and result:
                        print(f"Hole punch SUCCESS! Direct connection established.", file=sys.stderr)
                        print(f"Handshake time: {handshake_time_ms:.2f}ms", file=sys.stderr)

                        # Output results to stdout (YAML format)
                        print(f"handshakeTime: {handshake_time_ms:.2f}", file=sys.stdout)

                        # Success - return cleanly to allow nursery to close
                        return
                    else:
                        print(f"Hole punch FAILED. result={result}, has_direct={has_direct}", file=sys.stderr)
                        raise SystemExit(1)

    def _use_rust_relay_protocol_id_if_needed(self):
        """Use Rust relay HOP protocol ID when talking to a Rust relay.
        rust-libp2p uses /libp2p/circuit/relay/0.2.0/hop (protocols/relay/src/protocol.rs).
        STOP is handled by registering our own 0.2.0/stop handler in run_listener.
        """
        if self.relay_id and self.relay_id.lower().startswith("rust"):
            _circuit_transport_mod.PROTOCOL_ID = "/libp2p/circuit/relay/0.2.0/hop"
            if self.debug:
                print(
                    f"Using Rust relay protocol ID: {_circuit_transport_mod.PROTOCOL_ID}",
                    file=sys.stderr,
                )

    def _is_rust_relay(self) -> bool:
        return bool(self.relay_id and self.relay_id.lower().startswith("rust"))

    async def _handle_rust_stop_stream(self, stream, relay_protocol) -> None:
        """Handle incoming STOP stream from a Rust relay (length-delimited framing)."""
        try:
            payload = await _read_varint_prefixed_message(stream)
            parsed = _parse_rust_stop_message(payload)
            if parsed.get("type_pb") != 0:  # CONNECT=0
                try:
                    await _write_varint_prefixed_message(
                        stream, _encode_rust_stop_status_error(400)
                    )
                except Exception:
                    pass
                try:
                    await stream.close()
                except Exception:
                    pass
                return
            peer_id_bytes = parsed.get("peer_id")
            if not peer_id_bytes:
                try:
                    await _write_varint_prefixed_message(
                        stream, _encode_rust_stop_status_error(400)
                    )
                except Exception:
                    pass
                try:
                    await stream.close()
                except Exception:
                    pass
                return
            await _write_varint_prefixed_message(stream, _encode_rust_stop_status_ok())
            peer_id = ID(peer_id_bytes)
            remote_ma = f"/p2p/{peer_id.to_base58()}"
            await relay_protocol.handle_incoming_connection(stream, remote_ma)
        except Exception as e:
            logger.debug("Rust STOP stream error: %s", e)
            try:
                await stream.close()
            except Exception:
                pass

    async def _make_reservation_rust_relay(self, hop_stream, relay_peer_id) -> bool:
        """
        Make a reservation with a Rust relay using length-delimited framing and Rust proto layout.
        Returns True if status is OK and reservation present.
        """
        try:
            msg = _encode_rust_reserve_request()
            await _write_varint_prefixed_message(hop_stream, msg)
            payload = await _read_varint_prefixed_message(hop_stream)
            parsed = _parse_rust_hop_message(payload)
            if parsed.get("status") != RUST_STATUS_OK:
                return False
            if parsed.get("reservation") is None:
                return False
            return True
        except Exception as e:
            logger.debug("Rust relay reservation failed: %s", e)
            return False

    async def _dial_rust_relay(
        self,
        transport,
        relay_info,
        listener_peer_id,
    ):
        """
        Dial through a Rust relay: send CONNECT to relay targeting the listener
        (who has already RESERVEd). Returns the open circuit stream.
        """
        hop_stream = await self.host.new_stream(
            relay_info.peer_id, [_circuit_transport_mod.PROTOCOL_ID]
        )
        try:
            connect_msg = _encode_rust_connect_request(listener_peer_id.to_bytes())
            await _write_varint_prefixed_message(hop_stream, connect_msg)
            payload = await _read_varint_prefixed_message(hop_stream)
            parsed = _parse_rust_hop_message(payload)
            if parsed.get("status") != RUST_STATUS_OK:
                await hop_stream.close()
                raise RuntimeError(
                    f"Rust relay CONNECT failed: status={parsed.get('status')}"
                )
            if hasattr(transport, "_build_connection_from_hop_stream"):
                return await transport._build_connection_from_hop_stream(
                    hop_stream, relay_info.peer_id, listener_peer_id
                )
            return hop_stream
        except Exception:
            try:
                await hop_stream.close()
            except Exception:
                pass
            raise

    async def run(self):
        """Main entry point."""
        await self.connect_redis()
        self._use_rust_relay_protocol_id_if_needed()

        if self.is_dialer:
            await self.run_dialer()
        else:
            await self.run_listener()


def configure_logging():
    """Configure logging based on DEBUG env var."""
    debug = os.getenv("DEBUG", "false").lower() in ["true", "1", "yes", "debug"]
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s | %(name)s | %(levelname)s | %(message)s",
        stream=sys.stderr,
    )
    # Suppress overly verbose loggers
    if not debug:
        logging.getLogger("libp2p").setLevel(logging.WARNING)


async def main():
    configure_logging()
    try:
        peer = HolePunchPeer()
        await peer.run()
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    trio.run(main)
