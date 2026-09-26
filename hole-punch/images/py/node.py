import logging
import os
import sys
import time

import redis
import trio
from multiaddr import Multiaddr

from libp2p import new_host
from libp2p.host.ping import PingService
from libp2p.network.config import ConnectionConfig
from libp2p.peer.id import ID as PeerID
from libp2p.peer.peerinfo import info_from_p2p_addr
from libp2p.relay.circuit_v2.config import RelayConfig, RelayRole
from libp2p.relay.circuit_v2.dcutr import DCUtRProtocol
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
    for _h in logging.getLogger().handlers:
        _h.setLevel(logging.DEBUG)
    logging.getLogger("libp2p").setLevel(logging.DEBUG)

# Overall dialer budget: run-single-test.sh kills the compose project after 180s.
DIALER_TIMEOUT = 150.0


def getenv(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None:
        logger.error(f"Missing required environment variable: {name}")
        sys.exit(1)
    return val


def redis_client(redis_addr: str) -> redis.Redis:
    redis_host, redis_port = redis_addr.split(":")
    return redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)


async def wait_for_key(r: redis.Redis, key: str, timeout: float = 150.0) -> str:
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


def build_services(host):
    """Shared relay client + DCUtR stack (mirrors rust peer Behaviour)."""
    limits = RelayLimits(
        duration=3600,
        data=1024 * 1024 * 100,
        max_circuit_conns=10,
        max_reservations=5,
    )
    relay_config = RelayConfig(
        roles=RelayRole.STOP | RelayRole.CLIENT,
        limits=limits,
    )
    protocol = CircuitV2Protocol(host, limits=limits, allow_hop=False)
    transport = CircuitV2Transport(host, protocol, relay_config)
    discovery = RelayDiscovery(host, auto_reserve=False)
    dcutr_protocol = DCUtRProtocol(host)
    ping_service = PingService(host)
    return protocol, transport, discovery, dcutr_protocol, ping_service


async def run_listener() -> int:
    redis_addr = getenv("REDIS_ADDR")
    test_key = getenv("TEST_KEY")
    listen_ip = os.environ.get("LISTENER_IP", "0.0.0.0")
    r = redis_client(redis_addr)

    host = new_host(
        connection_config=ConnectionConfig(
            min_connections=0,
            low_watermark=0,   # Listener waits for dialer; no auto-dial
            high_watermark=0,  # Disable auto-connector entirely
        )
    )
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{listen_ip}/tcp/0")]):
        if os.environ.get("DEBUG", "false").lower() == "true":
            # libp2p resets logger levels at startup; re-assert.
            logging.getLogger().setLevel(logging.DEBUG)
            logging.getLogger("libp2p").setLevel(logging.DEBUG)
        peer_id = host.get_id()
        logger.info(f"Listener {peer_id} started")

        protocol, transport, discovery, dcutr_protocol, _ = build_services(host)
        async with background_trio_service(protocol):
            async with background_trio_service(discovery):
                async with background_trio_service(dcutr_protocol):
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

                    # Publish peer id only after the reservation is accepted,
                    # mirroring the rust peer's ReservationReqAccepted gate.
                    await trio.to_thread.run_sync(
                        r.set, f"{test_key}_listener_peer_id", peer_id.to_string()
                    )
                    logger.info("Published listener peer id, waiting for hole punch...")
                    while True:
                        await trio.sleep(3600)
    return 0


async def run_dialer() -> int:
    redis_addr = getenv("REDIS_ADDR")
    test_key = getenv("TEST_KEY")
    dialer_ip = os.environ.get("DIALER_IP", "0.0.0.0")
    r = redis_client(redis_addr)

    def fail(msg: str) -> int:
        logger.error(msg)
        print(f"error: {msg}", flush=True)
        return 1

    host = new_host(
        connection_config=ConnectionConfig(
            min_connections=0,
            low_watermark=1,
            high_watermark=50,
        )
    )
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{dialer_ip}/tcp/0")]):
        peer_id = host.get_id()
        logger.info(f"Dialer {peer_id} started")

        protocol, transport, discovery, dcutr_protocol, ping_service = build_services(
            host
        )
        async with background_trio_service(protocol):
            async with background_trio_service(discovery):
                async with background_trio_service(dcutr_protocol):
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

                    # Dial the listener through the relay circuit, mirroring the
                    # rust peer's relay/p2p-circuit/p2p dial.
                    relay_peer_str = relay_info.peer_id.to_string()
                    relay_base = str(relay_info.addrs[0])
                    if f"/p2p/{relay_peer_str}" not in relay_base:
                        relay_base = f"{relay_base}/p2p/{relay_peer_str}"
                    circuit_addr = Multiaddr(
                        f"{relay_base}/p2p-circuit/p2p/{listener_id_str}"
                    )
                    logger.info(f"Dialling listener through relay: {circuit_addr}")
                    with trio.fail_after(30.0):
                        await transport.dial(circuit_addr)
                    logger.info("Relayed circuit to listener established")

                    if os.environ.get("DEBUG", "false").lower() == "true":
                        # libp2p resets logger levels at startup; re-assert
                        # for the DCUtR phase.
                        logging.getLogger().setLevel(logging.DEBUG)
                        logging.getLogger("libp2p").setLevel(logging.DEBUG)

                    dcutr_start = time.monotonic()
                    await dcutr_protocol.event_started.wait()
                    # Best effort: the library also auto-drives hole punches
                    # for relayed peers, so a False here only means *this*
                    # attempt did not win. Poll for directness instead.
                    with trio.fail_after(60.0):
                        try:
                            await dcutr_protocol.initiate_hole_punch(listener_id)
                        except Exception as e:
                            logger.debug(f"Explicit hole punch attempt ended: {e}")
                    dcutr_elapsed_ms = (time.monotonic() - dcutr_start) * 1000.0

                    # Verify the direct path, then ping over it like the rust peer.
                    is_direct = False
                    deadline = trio.current_time() + 60.0
                    while trio.current_time() < deadline:
                        with trio.fail_after(30.0):
                            is_direct = await dcutr_protocol._verify_direct_connection(
                                listener_id
                            )
                        if is_direct:
                            break
                        await trio.sleep(1.0)
                    if not is_direct:
                        return fail("No direct connection after DCUtR")
                    logger.info("DCUtR hole punch succeeded")

                    with trio.fail_after(30.0):
                        rtts = await ping_service.ping(listener_id, ping_amt=1)
                    ping_rtt_ms = float(rtts[0])
                    handshake_ms = dcutr_elapsed_ms + ping_rtt_ms
                    logger.info(f"Ping over direct connection: {ping_rtt_ms:.2f}ms")

                    # Measurement block parsed by lib/run-single-test.sh
                    print("latency:", flush=True)
                    print(f"  handshake_plus_one_rtt: {handshake_ms:.2f}", flush=True)
                    print(f"  ping_rtt: {ping_rtt_ms:.2f}", flush=True)
                    print("  unit: ms", flush=True)
                    return 0


async def amain() -> int:
    is_dialer = getenv("IS_DIALER").lower() == "true"
    # TRANSPORT/SECURE_CHANNEL/MUXER are asserted by the matrix: this image
    # declares tcp/noise/yamux only (see images.yaml).
    transport = getenv("TRANSPORT", "tcp")
    secure = getenv("SECURE_CHANNEL", "noise")
    muxer = getenv("MUXER", "yamux")
    if (transport, secure, muxer) != ("tcp", "noise", "yamux"):
        logger.error(
            f"Unsupported combo (only tcp/noise/yamux): {transport}/{secure}/{muxer}"
        )
        return 1

    try:
        if is_dialer:
            with trio.fail_after(DIALER_TIMEOUT):
                return await run_dialer()
        else:
            return await run_listener()
    except trio.TooSlowError:
        msg = f"Dialer timed out after {DIALER_TIMEOUT}s"
        logger.error(msg)
        print(f"error: {msg}", flush=True)
        return 1
    except Exception as e:
        logger.exception(f"Test failed: {e}")
        print(f"error: {e}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(trio.run(amain))
