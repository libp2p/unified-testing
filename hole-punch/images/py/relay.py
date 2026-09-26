import logging
import os
import sys

import redis
import trio
from multiaddr import Multiaddr

from libp2p import new_host
from libp2p.network.config import ConnectionConfig
from libp2p.relay.circuit_v2.protocol import CircuitV2Protocol
from libp2p.relay.circuit_v2.resources import RelayLimits
from libp2p.tools.anyio_service import background_trio_service

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

if os.environ.get("DEBUG", "false").lower() == "true":
    logging.getLogger("libp2p").setLevel(logging.DEBUG)


async def amain() -> int:
    redis_addr = os.environ.get("REDIS_ADDR")
    test_key = os.environ.get("TEST_KEY")
    relay_ip = os.environ.get("RELAY_IP", "0.0.0.0")
    if not redis_addr or not test_key:
        logger.error("Missing required environment variables: REDIS_ADDR, TEST_KEY")
        return 1

    redis_host, redis_port = redis_addr.split(":")
    r = redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)

    host = new_host(
        connection_config=ConnectionConfig(
            min_connections=0,
            low_watermark=1,
            high_watermark=50,
        )
    )
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{relay_ip}/tcp/0")]):
        if os.environ.get("DEBUG", "false").lower() == "true":
            logging.getLogger().setLevel(logging.DEBUG)
            for _h in logging.getLogger().handlers:
                _h.setLevel(logging.DEBUG)
            logging.getLogger("libp2p").setLevel(logging.DEBUG)

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
            # Advertise the configured relay IP (not a wildcard listen addr).
            full_multiaddr = f"/ip4/{relay_ip}/tcp/{port}/p2p/{peer_id}"
            logger.info(f"Relay {peer_id} listening on {full_multiaddr}")

            await trio.to_thread.run_sync(
                r.set, f"{test_key}_relay_multiaddr", full_multiaddr
            )
            logger.info("Published relay multiaddr, serving indefinitely...")
            while True:
                await trio.sleep(3600)
    return 0


if __name__ == "__main__":
    sys.exit(trio.run(amain))
