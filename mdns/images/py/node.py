import logging
import os
import socket
import sys

import redis
import trio
from multiaddr import Multiaddr

from libp2p import new_host
from libp2p.custom_types import TProtocol
from libp2p.discovery.events.peerDiscovery import peerDiscovery
from libp2p.peer.id import ID as PeerID
from libp2p.peer.peerinfo import PeerInfo

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

PING_PROTO = TProtocol("/ping/1.0.0")


def setup_ping_handler(host):
    async def handle_ping(stream):
        buf = await stream.read(4)
        if buf == b"ping":
            await stream.write(b"pong")
        await stream.close()

    host.set_stream_handler(PING_PROTO, handle_ping)


async def main() -> int:
    role = os.environ.get("ROLE")
    redis_addr = os.environ.get("REDIS_ADDR")
    test_key = os.environ.get("TEST_KEY")

    if not all([role, redis_addr, test_key]):
        logger.error("Missing required environment variables: ROLE, REDIS_ADDR, TEST_KEY")
        return 1

    redis_host, redis_port = redis_addr.split(":")
    r = redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)

    def get_container_ip() -> str:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((redis_host, int(redis_port)))
        ip = s.getsockname()[0]
        s.close()
        return ip

    container_ip = await trio.to_thread.run_sync(get_container_ip)

    # NOTE: the discovery handler MUST be registered before the host starts.
    # PeerListener emits `peer_discovered` only on the first sighting of a
    # service (add_service); later sightings go through update_service, which
    # refreshes the peerstore but does NOT re-emit. Registering after the
    # redis wait below loses the one-shot emit whenever discovery wins the
    # race, and the test then times out even though the peer is known.
    # The peerstore is populated on every sighting regardless of handlers,
    # so it is used as a fallback below.
    discovered: list = []
    expected_holder: list = []

    def on_discovered(peer_info):
        try:
            if expected_holder and peer_info.peer_id.to_string() == expected_holder[0]:
                discovered.append(peer_info)
                logger.info(f"mDNS discovered expected peer {expected_holder[0]}")
        except Exception:
            pass

    peerDiscovery.register_peer_discovered_handler(on_discovered)
    try:
        return await _run_node(role, test_key, r, container_ip, discovered, expected_holder)
    finally:
        peerDiscovery.unregister_peer_discovered_handler(on_discovered)


async def _run_node(role, test_key, r, container_ip, discovered, expected_holder) -> int:
    # mDNS is enabled on both roles: advertiser broadcasts, discoverer listens.
    # host.run() starts the MDNSDiscovery service automatically.
    host = new_host(enable_mDNS=True)
    setup_ping_handler(host)
    listen_addr = Multiaddr(f"/ip4/{container_ip}/tcp/0")

    async with host.run(listen_addrs=[listen_addr]):
        addrs = host.get_addrs()
        while not addrs:
            await trio.sleep(0.1)
            addrs = host.get_addrs()

        port = addrs[0].value_for_protocol("tcp")
        my_id = host.get_id().to_string()
        my_multiaddr = f"/ip4/{container_ip}/tcp/{port}/p2p/{my_id}"
        logger.info(f"Node started in role '{role}' at {my_multiaddr}")

        if role == "advertiser":
            await trio.to_thread.run_sync(r.set, f"{test_key}_advertiser_id", my_id)
            await trio.to_thread.run_sync(r.set, f"{test_key}_advertiser_done", "1")
            logger.info("Advertiser broadcasting via mDNS, waiting indefinitely...")
            while True:
                await trio.sleep(3600)

        elif role == "discoverer":
            advertiser_id = None
            with trio.fail_after(60.0):
                while not advertiser_id:
                    advertiser_id = await trio.to_thread.run_sync(
                        r.get, f"{test_key}_advertiser_id"
                    )
                    if not advertiser_id:
                        await trio.sleep(0.5)
            logger.info(f"Expecting mDNS advertisement from {advertiser_id}")
            expected_holder.append(advertiser_id)

            target = None
            # Fast path: the peer may already be in the peerstore (the emit
            # fired before we knew which ID to expect). The listener populates
            # the peerstore on every sighting, independent of handlers.
            try:
                pid = PeerID.from_string(advertiser_id)
                known_addrs = host.get_peerstore().addrs(pid)
                if known_addrs:
                    target = PeerInfo(pid, known_addrs)
                    logger.info(f"Advertiser already in peerstore: {known_addrs}")
            except Exception as e:
                logger.debug(f"Peerstore fast-path miss: {e}")

            if target is None:
                try:
                    with trio.fail_after(60.0):
                        while not discovered:
                            # Re-check peerstore each tick: update_service
                            # refreshes it without re-emitting.
                            try:
                                pid = PeerID.from_string(advertiser_id)
                                known_addrs = host.get_peerstore().addrs(pid)
                                if known_addrs:
                                    target = PeerInfo(pid, known_addrs)
                                    logger.info(
                                        f"Advertiser found via peerstore: {known_addrs}"
                                    )
                                    break
                            except Exception:
                                pass
                            await trio.sleep(0.5)
                        else:
                            target = discovered[0]
                except trio.TooSlowError:
                    logger.error("Test Failed: Timeout waiting for mDNS discovery")
                    print("error: Timeout waiting for mDNS discovery", flush=True)
                    print("status: fail", flush=True)
                    return 1
                if target is None and discovered:
                    target = discovered[0]

            if target is None:
                logger.error("Test Failed: Timeout waiting for mDNS discovery")
                print("error: Timeout waiting for mDNS discovery", flush=True)
                print("status: fail", flush=True)
                return 1

            logger.info(f"Discovered peer addrs: {target.addrs}")

            try:
                with trio.fail_after(15.0):
                    await host.connect(target)
                    stream = await host.new_stream(target.peer_id, [PING_PROTO])
                    await stream.write(b"ping")
                    resp = await stream.read(4)
                    await stream.close()
                    if resp == b"pong":
                        logger.info("Discoverer successfully pinged advertiser!")
                        print("status: pass", flush=True)
                        return 0
                    logger.error(f"Test Failed: Unexpected ping response: {resp}")
                    print(f"error: Unexpected ping response: {resp}", flush=True)
                    print("status: fail", flush=True)
                    return 1
            except Exception as e:
                logger.error(f"Test Failed: Dial to advertiser failed: {e}")
                print(f"error: Dial to advertiser failed: {e}", flush=True)
                print("status: fail", flush=True)
                return 1
        else:
            logger.error(f"Unknown role: {role}")
            return 1


if __name__ == "__main__":
    sys.exit(trio.run(main))
