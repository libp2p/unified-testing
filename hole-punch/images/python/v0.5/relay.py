#!/usr/bin/env python3
"""
py-libp2p hole-punch test relay server implementation.

Supports both Python (py-libp2p 2.0.0 wire format) and Rust (rust-libp2p
0.2.0 varint-length-delimited wire format) peers.
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
from libp2p.peer.id import ID
from libp2p.relay.circuit_v2.protocol import (
    CircuitV2Protocol,
    PROTOCOL_ID,
    STOP_PROTOCOL_ID,
)
from libp2p.relay.circuit_v2.config import RelayConfig, RelayRole
from libp2p.relay.circuit_v2.resources import RelayLimits
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

logger = logging.getLogger("hole-punch-relay")

# rust-libp2p uses these protocol IDs (version 0.2.0)
RUST_HOP_PROTOCOL_ID = "/libp2p/circuit/relay/0.2.0/hop"
RUST_STOP_PROTOCOL_ID = "/libp2p/circuit/relay/0.2.0/stop"

RUST_STATUS_OK = 100
RUST_STATUS_RESOURCE_LIMIT_EXCEEDED = 201


# --- Varint + protobuf helpers (same wire format as quick_protobuf_codec) ---

def _varint_encode(n: int) -> bytes:
    buf = []
    while n > 0x7F:
        buf.append((n & 0x7F) | 0x80)
        n >>= 7
    buf.append(n & 0x7F)
    return bytes(buf)


def _varint_decode(buf: bytes, start: int = 0) -> tuple[int, int]:
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


async def _read_varint_prefixed(stream) -> bytes:
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


async def _write_varint_prefixed(stream, message: bytes) -> None:
    prefix = _varint_encode(len(message))
    await stream.write(prefix + message)


# --- Rust protobuf encoding/decoding for HopMessage/StopMessage ---
# Proto layout from circuit-relay-v2 message.proto:
#   HopMessage:  type(1), peer(2), reservation(3), limit(4), status(5)
#   StopMessage: type(1), peer(2), limit(3), status(4)
#   Peer:        id(1), addrs(2)
#   Reservation: expire(1), addrs(2), voucher(3)
#   Limit:       duration(1), data(2)

def _parse_rust_hop_message(buf: bytes) -> dict:
    out = {"type_pb": None, "status": None, "peer_id": None}
    i = 0
    while i < len(buf):
        tag = buf[i]
        i += 1
        field_num = tag >> 3
        wire = tag & 7
        if wire == 0:
            n, consumed = _varint_decode(buf, i)
            i += consumed
            if field_num == 1:
                out["type_pb"] = n
            elif field_num == 5:
                out["status"] = n
        elif wire == 2:
            length, consumed = _varint_decode(buf, i)
            i += consumed
            end = i + length
            if end > len(buf):
                break
            if field_num == 2:
                out["peer_id"] = _extract_peer_id(buf[i:end])
            i = end
    return out


def _extract_peer_id(peer_msg: bytes) -> bytes | None:
    i = 0
    while i < len(peer_msg):
        tag = peer_msg[i]
        i += 1
        fn = tag >> 3
        w = tag & 7
        if w == 2 and fn == 1:
            length, consumed = _varint_decode(peer_msg, i)
            i += consumed
            return bytes(peer_msg[i : i + length])
        elif w == 0:
            _, consumed = _varint_decode(peer_msg, i)
            i += consumed
        elif w == 2:
            length, consumed = _varint_decode(peer_msg, i)
            i += consumed + length
    return None


def _encode_hop_status_ok_with_reservation(
    expire_unix: int,
    relay_addrs: list[bytes],
    duration: int,
    data: int,
) -> bytes:
    """Encode HopMessage { type=STATUS, status=OK, reservation={...}, limit={...} }."""
    parts = []
    # field 1: type = STATUS (2)
    parts.append(b"\x08\x02")
    # field 5: status = OK (100)
    parts.append(b"\x28" + _varint_encode(RUST_STATUS_OK))
    # field 3: reservation message
    res_parts = []
    # reservation.expire (field 1, varint)
    res_parts.append(b"\x08" + _varint_encode(expire_unix))
    # reservation.addrs (field 2, repeated bytes)
    for addr in relay_addrs:
        res_parts.append(b"\x12" + _varint_encode(len(addr)) + addr)
    res_inner = b"".join(res_parts)
    parts.append(b"\x1a" + _varint_encode(len(res_inner)) + res_inner)
    # field 4: limit message
    lim_parts = []
    lim_parts.append(b"\x08" + _varint_encode(duration))
    lim_parts.append(b"\x10" + _varint_encode(data))
    lim_inner = b"".join(lim_parts)
    parts.append(b"\x22" + _varint_encode(len(lim_inner)) + lim_inner)
    return b"".join(parts)


def _encode_hop_status_error(status_code: int) -> bytes:
    """HopMessage { type=STATUS, status=<code> }."""
    return b"\x08\x02\x28" + _varint_encode(status_code)


def _encode_stop_connect(src_peer_id_bytes: bytes, duration: int, data: int) -> bytes:
    """StopMessage { type=CONNECT, peer={id=src_peer_id}, limit={duration, data} }."""
    parts = []
    # field 1: type = CONNECT (0)
    parts.append(b"\x08\x00")
    # field 2: peer message
    peer_inner = b"\x0a" + _varint_encode(len(src_peer_id_bytes)) + src_peer_id_bytes
    parts.append(b"\x12" + _varint_encode(len(peer_inner)) + peer_inner)
    # field 3: limit message
    lim_parts = []
    lim_parts.append(b"\x08" + _varint_encode(duration))
    lim_parts.append(b"\x10" + _varint_encode(data))
    lim_inner = b"".join(lim_parts)
    parts.append(b"\x1a" + _varint_encode(len(lim_inner)) + lim_inner)
    return b"".join(parts)


def _parse_rust_stop_response(buf: bytes) -> dict:
    """Parse StopMessage STATUS response: type(1), status(4)."""
    out = {"type_pb": None, "status": None}
    i = 0
    while i < len(buf):
        if i >= len(buf):
            break
        tag = buf[i]
        i += 1
        field_num = tag >> 3
        wire = tag & 7
        if wire == 0:
            n, consumed = _varint_decode(buf, i)
            i += consumed
            if field_num == 1:
                out["type_pb"] = n
            elif field_num == 4:
                out["status"] = n
        elif wire == 2:
            length, consumed = _varint_decode(buf, i)
            i += consumed
            i += length
    return out


class HolePunchRelay:
    def __init__(self):
        self.redis_addr = os.getenv("REDIS_ADDR")
        self.test_key = os.getenv("TEST_KEY")
        self.transport = os.getenv("TRANSPORT", "tcp")
        self.secure_channel = os.getenv("SECURE_CHANNEL")
        self.muxer = os.getenv("MUXER")
        self.relay_ip = os.getenv("RELAY_IP", "0.0.0.0")
        self.debug = os.getenv("DEBUG", "false").lower() == "true"

        if not self.redis_addr:
            raise ValueError("REDIS_ADDR environment variable is required")
        if not self.test_key:
            raise ValueError("TEST_KEY environment variable is required")

        if ":" in self.redis_addr:
            host, port = self.redis_addr.split(":")
            self.redis_host, self.redis_port = host, int(port)
        else:
            self.redis_host = self.redis_addr
            self.redis_port = 6379

        self.redis_client = None
        self.host = None
        # Peers that connected via 0.2.0/hop (Rust wire format)
        self._rust_peers: set[str] = set()
        self._relay_protocol = None

    def create_security_options(self):
        key_pair = create_new_key_pair()

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
        if self.transport == "quic-v1":
            return None

        if self.muxer == "yamux":
            return create_yamux_muxer_option()
        elif self.muxer == "mplex":
            return create_mplex_muxer_option()
        else:
            raise ValueError(f"Unsupported muxer: {self.muxer}")

    def create_listen_address(self, port: int = 4001):
        if self.transport == "tcp":
            return multiaddr.Multiaddr(f"/ip4/{self.relay_ip}/tcp/{port}")
        elif self.transport == "quic-v1":
            return multiaddr.Multiaddr(f"/ip4/{self.relay_ip}/udp/{port}/quic-v1")
        elif self.transport == "ws":
            return multiaddr.Multiaddr(f"/ip4/{self.relay_ip}/tcp/{port}/ws")
        elif self.transport == "wss":
            return multiaddr.Multiaddr(f"/ip4/{self.relay_ip}/tcp/{port}/wss")
        else:
            raise ValueError(f"Unsupported transport: {self.transport}")

    async def connect_redis(self):
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

    # ---- Rust HOP handler (varint-length-delimited, 0.2.0 proto layout) ----

    async def _handle_rust_hop_stream(self, stream) -> None:
        """Handle HOP streams from Rust peers (0.2.0/hop, varint framing)."""
        remote_peer_id = stream.muxed_conn.peer_id
        remote_id = str(remote_peer_id)
        self._rust_peers.add(remote_id)
        print(f"Rust HOP stream from {remote_id}", file=sys.stderr)
        try:
            payload = await _read_varint_prefixed(stream)
            parsed = _parse_rust_hop_message(payload)
            msg_type = parsed.get("type_pb")

            if msg_type == 0:  # RESERVE
                await self._handle_rust_reserve(stream, remote_peer_id)
            elif msg_type == 1:  # CONNECT
                dst_peer_id_bytes = parsed.get("peer_id")
                if not dst_peer_id_bytes:
                    await _write_varint_prefixed(stream, _encode_hop_status_error(400))
                    return
                dst_peer_id = ID(dst_peer_id_bytes)
                await self._handle_rust_connect(stream, remote_peer_id, dst_peer_id)
            else:
                await _write_varint_prefixed(stream, _encode_hop_status_error(401))
        except Exception as e:
            print(f"Error in Rust HOP handler from {remote_id}: {e}", file=sys.stderr)
            try:
                await _write_varint_prefixed(stream, _encode_hop_status_error(400))
            except Exception:
                pass

    async def _handle_rust_reserve(self, stream, remote_peer_id) -> None:
        """Process a Rust RESERVE request and send varint-delimited response."""
        rp = self._relay_protocol
        peer_id = remote_peer_id
        pid_str = str(peer_id)

        if rp.resource_manager.has_reservation(peer_id):
            ttl = rp.resource_manager.refresh_reservation(peer_id)
        elif rp.resource_manager.can_accept_reservation(peer_id):
            ttl = rp.resource_manager.reserve(peer_id)
        else:
            print(f"Reservation limit exceeded for {pid_str}", file=sys.stderr)
            await _write_varint_prefixed(
                stream, _encode_hop_status_error(RUST_STATUS_RESOURCE_LIMIT_EXCEEDED)
            )
            return

        expire_unix = int(time.time() + ttl)
        relay_addrs = []
        try:
            for addr in self.host.get_peerstore().addrs(self.host.get_id()):
                relay_addrs.append(
                    multiaddr.Multiaddr(
                        str(addr) + "/p2p/" + str(self.host.get_id())
                    ).to_bytes()
                )
        except Exception:
            pass
        if not relay_addrs:
            relay_addrs.append(self._listen_addr_with_p2p().to_bytes())

        response = _encode_hop_status_ok_with_reservation(
            expire_unix=expire_unix,
            relay_addrs=relay_addrs,
            duration=3600,
            data=100 * 1024 * 1024,
        )
        await _write_varint_prefixed(stream, response)
        print(f"Reservation OK for Rust peer {pid_str} (ttl={ttl}s)", file=sys.stderr)

    async def _handle_rust_connect(self, hop_stream, src_peer_id, dst_peer_id) -> None:
        """
        Handle a Rust CONNECT request: open STOP to destination, relay data.
        The source (dialer) is Rust so HOP uses varint framing.
        """
        dst_id_str = str(dst_peer_id)
        is_rust_dst = dst_id_str in self._rust_peers
        print(
            f"Rust CONNECT: src={src_peer_id} -> dst={dst_peer_id} "
            f"(dst_rust={is_rust_dst})",
            file=sys.stderr,
        )

        try:
            dst_stream = await self._open_stop_to_peer(dst_peer_id, src_peer_id, is_rust_dst)
        except Exception as e:
            print(f"Failed STOP to {dst_id_str}: {e}", file=sys.stderr)
            await _write_varint_prefixed(hop_stream, _encode_hop_status_error(203))
            return

        # Send HOP STATUS OK to the Rust source (varint-delimited)
        await _write_varint_prefixed(hop_stream, b"\x08\x02\x28\x64")
        print(f"Relaying: {src_peer_id} <-> {dst_peer_id}", file=sys.stderr)

        async with trio.open_nursery() as nursery:
            nursery.start_soon(self._relay_data, hop_stream, dst_stream)
            nursery.start_soon(self._relay_data, dst_stream, hop_stream)

    # ---- Wrapped Python HOP CONNECT handler (destination may be Rust) ----

    async def _handle_py_hop_stream(self, stream) -> None:
        """
        Handle HOP from Python peers. Delegates to the default py-libp2p handler
        for RESERVE but intercepts CONNECT to support Rust destinations.
        """
        remote_peer_id = stream.muxed_conn.peer_id
        from libp2p.relay.circuit_v2.protocol import HopMessage
        try:
            while True:
                with trio.fail_after(60):
                    msg_bytes = await stream.read(1024)
                    if not msg_bytes:
                        return

                hop_msg = HopMessage()
                hop_msg.ParseFromString(msg_bytes)

                if hop_msg.type == HopMessage.RESERVE:
                    await self._relay_protocol._handle_reserve(stream, hop_msg)
                    continue

                if hop_msg.type == HopMessage.CONNECT:
                    dst_peer_id = ID(hop_msg.peer)
                    dst_id_str = str(dst_peer_id)

                    if dst_id_str in self._rust_peers:
                        await self._handle_py_connect_to_rust(
                            stream, remote_peer_id, dst_peer_id
                        )
                    else:
                        await self._relay_protocol._handle_connect(stream, hop_msg)
                    return

        except trio.TooSlowError:
            return
        except Exception as e:
            print(
                f"Unexpected error handling hop stream from "
                f"{remote_peer_id}: {e}",
                file=sys.stderr,
            )

    async def _handle_py_connect_to_rust(self, hop_stream, src_peer_id, dst_peer_id) -> None:
        """Python dialer CONNECT → Rust listener: open Rust STOP, relay."""
        print(
            f"Py CONNECT to Rust dst: src={src_peer_id} -> dst={dst_peer_id}",
            file=sys.stderr,
        )
        try:
            dst_stream = await self._open_stop_to_peer(
                dst_peer_id, src_peer_id, is_rust_dst=True
            )
        except Exception as e:
            print(f"Failed STOP to Rust {dst_peer_id}: {e}", file=sys.stderr)
            await self._send_py_hop_error(hop_stream, f"Failed: {e}")
            return

        # Send py-format HOP STATUS OK to the Python source
        await self._send_py_hop_ok(hop_stream)
        print(f"Relaying: {src_peer_id} <-> {dst_peer_id}", file=sys.stderr)

        async with trio.open_nursery() as nursery:
            nursery.start_soon(self._relay_data, hop_stream, dst_stream)
            nursery.start_soon(self._relay_data, dst_stream, hop_stream)

    # ---- STOP stream opener (supports both Python and Rust destinations) ----

    async def _open_stop_to_peer(self, dst_peer_id, src_peer_id, is_rust_dst: bool):
        """Open a STOP stream to the destination and perform the CONNECT handshake."""
        if is_rust_dst:
            return await self._open_rust_stop(dst_peer_id, src_peer_id)
        else:
            return await self._open_py_stop(dst_peer_id, src_peer_id)

    async def _open_rust_stop(self, dst_peer_id, src_peer_id):
        """Open STOP to a Rust peer: 0.2.0/stop + varint framing."""
        dst_stream = await self.host.new_stream(dst_peer_id, [RUST_STOP_PROTOCOL_ID])
        stop_msg = _encode_stop_connect(
            src_peer_id_bytes=src_peer_id.to_bytes(),
            duration=3600,
            data=100 * 1024 * 1024,
        )
        await _write_varint_prefixed(dst_stream, stop_msg)
        resp_payload = await _read_varint_prefixed(dst_stream)
        parsed = _parse_rust_stop_response(resp_payload)
        if parsed.get("status") != RUST_STATUS_OK:
            await dst_stream.close()
            raise ConnectionError(
                f"Rust STOP rejected: status={parsed.get('status')}"
            )
        return dst_stream

    async def _open_py_stop(self, dst_peer_id, src_peer_id):
        """Open STOP to a Python peer: 2.0.0/stop + raw protobuf."""
        from libp2p.relay.circuit_v2.protocol import StopMessage

        dst_stream = await self.host.new_stream(dst_peer_id, [STOP_PROTOCOL_ID])
        stop_msg = StopMessage(
            type=StopMessage.CONNECT,
            peer=src_peer_id.to_bytes(),
        )
        await dst_stream.write(stop_msg.SerializeToString())
        resp_bytes = await dst_stream.read(1024)
        resp = StopMessage()
        resp.ParseFromString(resp_bytes)
        if resp.HasField("status"):
            from libp2p.relay.circuit_v2.protocol import StatusCode
            status_code = getattr(resp.status, "code", StatusCode.OK)
            if status_code != StatusCode.OK:
                await dst_stream.close()
                raise ConnectionError(f"Py STOP rejected: {status_code}")
        return dst_stream

    # ---- Helpers ----

    async def _send_py_hop_ok(self, stream) -> None:
        """Send a Python-format HOP STATUS OK response."""
        from libp2p.relay.circuit_v2.protocol import HopMessage, StatusCode
        from libp2p.relay.circuit_v2.protocol import create_status

        status = create_status(code=StatusCode.OK, message="OK")
        resp = HopMessage(type=HopMessage.STATUS, status=status)
        await stream.write(resp.SerializeToString())

    async def _send_py_hop_error(self, stream, message: str) -> None:
        from libp2p.relay.circuit_v2.protocol import HopMessage, StatusCode
        from libp2p.relay.circuit_v2.protocol import create_status

        status = create_status(code=StatusCode.CONNECTION_FAILED, message=message)
        resp = HopMessage(type=HopMessage.STATUS, status=status)
        try:
            await stream.write(resp.SerializeToString())
        except Exception:
            pass

    async def _relay_data(self, src, dst) -> None:
        try:
            while True:
                data = await src.read(4096)
                if not data:
                    break
                await dst.write(data)
        except Exception:
            pass

    def _listen_addr_with_p2p(self):
        return multiaddr.Multiaddr(
            str(self.create_listen_address(4001))
            + "/p2p/"
            + str(self.host.get_id())
        )

    async def run(self):
        print("Starting RELAY server...", file=sys.stderr)
        print(f"  TRANSPORT: {self.transport}", file=sys.stderr)
        print(f"  SECURE_CHANNEL: {self.secure_channel}", file=sys.stderr)
        print(f"  MUXER: {self.muxer}", file=sys.stderr)
        print(f"  RELAY_IP: {self.relay_ip}", file=sys.stderr)

        await self.connect_redis()

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

        limits = RelayLimits(
            duration=3600,
            data=100 * 1024 * 1024,
            max_circuit_conns=10,
            max_reservations=5,
        )

        relay_config = RelayConfig(
            roles=RelayRole.HOP | RelayRole.STOP | RelayRole.CLIENT,
            limits=limits,
        )

        self._relay_protocol = CircuitV2Protocol(
            self.host, limits=limits, allow_hop=True
        )

        async with self.host.run(listen_addrs=[listen_addr]):
            async with background_trio_service(self._relay_protocol):
                await self._relay_protocol.event_started.wait()

                # Register handlers AFTER relay protocol startup so ours overwrite
                # its defaults (otherwise CONNECT would use 2.0.0/stop for Rust dst).
                self.host.set_stream_handler(
                    PROTOCOL_ID, self._handle_py_hop_stream
                )
                self.host.set_stream_handler(
                    STOP_PROTOCOL_ID,
                    self._relay_protocol._handle_stop_stream,
                )
                self.host.set_stream_handler(
                    RUST_HOP_PROTOCOL_ID,
                    self._handle_rust_hop_stream,
                )
                self.host.set_stream_handler(
                    RUST_STOP_PROTOCOL_ID,
                    self._relay_protocol._handle_stop_stream,
                )

                CircuitV2Transport(self.host, self._relay_protocol, relay_config)

                peer_id = str(self.host.get_id())
                relay_multiaddr = f"{str(listen_addr)}/p2p/{peer_id}"

                print(f"Relay peer ID: {peer_id}", file=sys.stderr)
                print(f"Relay multiaddr: {relay_multiaddr}", file=sys.stderr)

                redis_key = f"{self.test_key}_relay_multiaddr"
                self.redis_client.set(redis_key, relay_multiaddr)
                print(
                    f"Published relay multiaddr to Redis key: {redis_key}",
                    file=sys.stderr,
                )

                print("Relay server ready, accepting connections...", file=sys.stderr)
                await trio.sleep_forever()


def configure_logging():
    debug = os.getenv("DEBUG", "false").lower() in ["true", "1", "yes", "debug"]
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s | %(name)s | %(levelname)s | %(message)s",
        stream=sys.stderr,
    )
    if not debug:
        logging.getLogger("libp2p").setLevel(logging.WARNING)


async def main():
    configure_logging()
    try:
        relay = HolePunchRelay()
        await relay.run()
    except Exception as e:
        print(f"Fatal error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    trio.run(main)
