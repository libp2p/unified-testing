"""Relay (circuit v2) interop node: relay / listener / dialer roles.

The listener reserves a slot on the relay and serves a fixed-length echo
protocol; the dialer dials the listener through a p2p-circuit address and
verifies the echo. Roles mirror the rendezvous suite (ROLE env var).
"""

import logging
import os
import socket
import sys

import redis
import trio
from multiaddr import Multiaddr

from libp2p import new_host
from libp2p.custom_types import TProtocol
from libp2p.network.config import ConnectionConfig
from libp2p.peer.id import ID as PeerID
from libp2p.peer.peerinfo import info_from_p2p_addr
from libp2p.relay.circuit_v2.config import RelayConfig, RelayRole
from libp2p.relay.circuit_v2.discovery import RelayDiscovery
from libp2p.relay.circuit_v2.protocol import CircuitV2Protocol
from libp2p.relay.circuit_v2.resources import RelayLimits
from libp2p.relay.circuit_v2.transport import CircuitV2Transport
from libp2p.tools.anyio_service import background_trio_service

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

if os.environ.get("DEBUG", "false").lower() == "true":
    logging.getLogger().setLevel(logging.DEBUG)
    logging.getLogger("libp2p").setLevel(logging.DEBUG)

ECHO_PROTO = TProtocol("/relay-echo/1.0.0")
ECHO_MSG = b"hello-relay"


def getenv(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None:
        logger.error(f"Missing required environment variable: {name}")
        sys.exit(1)
    return val


def redis_client(redis_addr: str) -> redis.Redis:
    redis_host, redis_port = redis_addr.split(":")
    return redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)


def container_ip(redis_addr: str) -> str:
    redis_host, redis_port = redis_addr.split(":")
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect((redis_host, int(redis_port)))
    ip = s.getsockname()[0]
    s.close()
    return ip


async def wait_for_key(r: redis.Redis, key: str, timeout: float = 90.0) -> str:
    logger.info(f"Waiting for Redis key '{key}'...")
    deadline = trio.current_time() + timeout
    while trio.current_time() < deadline:
        val = await trio.to_thread.run_sync(r.get, key)
        if val:
            logger.info(f"Got Redis key '{key}'")
            return val
        await trio.sleep(0.5)
    return ""


async def make_reservation(discovery: RelayDiscovery, relay_id: PeerID) -> bool:
    for _ in range(60):
        try:
            await discovery.discover_relays()
            if await discovery.make_reservation(relay_id):
                logger.info(f"Relay reservation accepted by {relay_id}")
                return True
        except Exception as e:
            logger.debug(f"Reservation attempt failed: {e}")
        await trio.sleep(1.0)
    return False


async def handle_echo(stream) -> None:
    try:
        buf = b""
        while len(buf) < len(ECHO_MSG):
            chunk = await stream.read(len(ECHO_MSG) - len(buf))
            if not chunk:
                break
            buf += chunk
        if buf:
            await stream.write(buf)
    except Exception as e:
        logger.debug(f"Echo handler error: {e}")
    finally:
        try:
            await stream.close()
        except Exception:
            pass


async def run_relay() -> int:
    redis_addr = getenv("REDIS_ADDR")
    test_key = getenv("TEST_KEY")
    r = redis_client(redis_addr)
    ip = container_ip(redis_addr)

    host = new_host(
        connection_config=ConnectionConfig(
            min_connections=0,
            low_watermark=1,
            high_watermark=100,
        )
    )
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{ip}/tcp/0")]):
        limits = RelayLimits(
            duration=3600,
            data=1024 * 1024 * 100,
            max_circuit_conns=100,
            max_reservations=100,
        )
        protocol = CircuitV2Protocol(host, limits=limits, allow_hop=True)
        async with background_trio_service(protocol):
            addrs = host.get_addrs()
            while not addrs:
                await trio.sleep(0.1)
                addrs = host.get_addrs()
            port = addrs[0].value_for_protocol("tcp")
            peer_id = host.get_id().to_string()
            full_multiaddr = f"/ip4/{ip}/tcp/{port}/p2p/{peer_id}"
            logger.info(f"Relay {peer_id} listening on {full_multiaddr}")
            await trio.to_thread.run_sync(
                r.set, f"{test_key}_relay_multiaddr", full_multiaddr
            )
            logger.info("Published relay multiaddr, serving indefinitely...")
            while True:
                await trio.sleep(3600)
    return 0


async def run_listener() -> int:
    redis_addr = getenv("REDIS_ADDR")
    test_key = getenv("TEST_KEY")
    r = redis_client(redis_addr)
    ip = container_ip(redis_addr)

    host = new_host(
        connection_config=ConnectionConfig(
            min_connections=0,
            low_watermark=0,
            high_watermark=0,
        )
    )
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{ip}/tcp/0")]):
        peer_id = host.get_id()
        logger.info(f"Listener {peer_id} started")
        host.set_stream_handler(ECHO_PROTO, handle_echo)

        limits = RelayLimits(
            duration=3600,
            data=1024 * 1024 * 100,
            max_circuit_conns=10,
            max_reservations=10,
        )
        relay_config = RelayConfig(
            roles=RelayRole.STOP | RelayRole.CLIENT, limits=limits
        )
        protocol = CircuitV2Protocol(host, limits=limits, allow_hop=False)
        CircuitV2Transport(host, protocol, relay_config)
        discovery = RelayDiscovery(host, auto_reserve=False)
        async with background_trio_service(protocol):
            async with background_trio_service(discovery):
                relay_addr = await wait_for_key(r, f"{test_key}_relay_multiaddr")
                if not relay_addr:
                    logger.error("Timeout waiting for relay multiaddr")
                    return 1
                relay_info = info_from_p2p_addr(Multiaddr(relay_addr))
                with trio.fail_after(30.0):
                    await host.connect(relay_info)
                logger.info(f"Connected to relay {relay_info.peer_id}")

                if not await make_reservation(discovery, relay_info.peer_id):
                    logger.error("Relay never accepted our reservation")
                    return 1

                await trio.to_thread.run_sync(
                    r.set, f"{test_key}_listener_peer_id", peer_id.to_string()
                )
                logger.info("Published listener peer id, waiting for dialer...")
                while True:
                    await trio.sleep(3600)
    return 0


async def run_dialer() -> int:
    redis_addr = getenv("REDIS_ADDR")
    test_key = getenv("TEST_KEY")
    r = redis_client(redis_addr)
    ip = container_ip(redis_addr)

    def fail(msg: str) -> int:
        logger.error(msg)
        print(f"error: {msg}", flush=True)
        return 1

    host = new_host(
        connection_config=ConnectionConfig(
            min_connections=0,
            low_watermark=0,
            high_watermark=0,
        )
    )
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{ip}/tcp/0")]):
        peer_id = host.get_id()
        logger.info(f"Dialer {peer_id} started")

        limits = RelayLimits(
            duration=3600,
            data=1024 * 1024 * 100,
            max_circuit_conns=10,
            max_reservations=10,
        )
        relay_config = RelayConfig(
            roles=RelayRole.STOP | RelayRole.CLIENT, limits=limits
        )
        protocol = CircuitV2Protocol(host, limits=limits, allow_hop=False)
        transport = CircuitV2Transport(host, protocol, relay_config)
        discovery = RelayDiscovery(host, auto_reserve=False)
        async with background_trio_service(protocol):
            async with background_trio_service(discovery):
                relay_addr = await wait_for_key(r, f"{test_key}_relay_multiaddr")
                if not relay_addr:
                    return fail("Timeout waiting for relay multiaddr")
                relay_info = info_from_p2p_addr(Multiaddr(relay_addr))
                with trio.fail_after(30.0):
                    await host.connect(relay_info)
                logger.info(f"Connected to relay {relay_info.peer_id}")

                if not await make_reservation(discovery, relay_info.peer_id):
                    return fail("Relay never accepted our reservation")

                listener_id_str = await wait_for_key(
                    r, f"{test_key}_listener_peer_id"
                )
                if not listener_id_str:
                    return fail("Timeout waiting for listener peer id")
                listener_id = PeerID.from_string(listener_id_str)

                relay_peer_str = relay_info.peer_id.to_string()
                relay_base = str(relay_info.addrs[0])
                if f"/p2p/{relay_peer_str}" not in relay_base:
                    relay_base = f"{relay_base}/p2p/{relay_peer_str}"
                circuit_addr = Multiaddr(
                    f"{relay_base}/p2p-circuit/p2p/{listener_id_str}"
                )
                logger.info(f"Dialling listener through relay: {circuit_addr}")

                # Retry while the listener's reservation propagates.
                deadline = trio.current_time() + 90.0
                dialed = False
                last_err: Exception | None = None
                while trio.current_time() < deadline:
                    try:
                        with trio.fail_after(15.0):
                            await transport.dial(circuit_addr)
                        dialed = True
                        break
                    except Exception as e:
                        last_err = e
                        logger.debug(f"Circuit dial retry: {e}")
                        await trio.sleep(2.0)
                if not dialed:
                    return fail(f"Circuit dial failed: {last_err}")
                logger.info("Relayed circuit to listener established")

                try:
                    with trio.fail_after(15.0):
                        stream = await host.new_stream(listener_id, [ECHO_PROTO])
                        await stream.write(ECHO_MSG)
                        resp = b""
                        while len(resp) < len(ECHO_MSG):
                            chunk = await stream.read(len(ECHO_MSG) - len(resp))
                            if not chunk:
                                break
                            resp += chunk
                        await stream.close()
                except Exception as e:
                    return fail(f"Echo stream failed: {e}")
                if resp == ECHO_MSG:
                    logger.info("Echo verified over relayed connection")
                    print("status: pass", flush=True)
                    return 0
                return fail(f"Unexpected echo response: {resp!r}")


async def amain() -> int:
    role = getenv("ROLE")
    try:
        if role == "relay":
            return await run_relay()
        if role == "listener":
            return await run_listener()
        if role == "dialer":
            return await run_dialer()
        logger.error(f"Unknown role: {role}")
        return 1
    except Exception as e:
        logger.exception(f"Test failed: {e}")
        print(f"error: {e}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(trio.run(amain))
