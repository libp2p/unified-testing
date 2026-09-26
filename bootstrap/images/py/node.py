import logging
import os
import socket
import sys

import redis
import trio
from multiaddr import Multiaddr

from libp2p import new_host
from libp2p.custom_types import TProtocol
from libp2p.peer.id import ID as PeerID
from libp2p.peer.peerinfo import info_from_p2p_addr

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
    listen_addr = Multiaddr(f"/ip4/{container_ip}/tcp/0")

    if role == "bootstrap":
        host = new_host()
        setup_ping_handler(host)
        async with host.run(listen_addrs=[listen_addr]):
            addrs = host.get_addrs()
            while not addrs:
                await trio.sleep(0.1)
                addrs = host.get_addrs()

            port = addrs[0].value_for_protocol("tcp")
            my_multiaddr = (
                f"/ip4/{container_ip}/tcp/{port}/p2p/{host.get_id().to_string()}"
            )
            logger.info(f"Bootstrap node at {my_multiaddr}")
            await trio.to_thread.run_sync(r.set, f"{test_key}_bootstrap_addr", my_multiaddr)
            await trio.to_thread.run_sync(r.set, f"{test_key}_bootstrap_done", "1")
            logger.info("Bootstrap node waiting indefinitely...")
            while True:
                await trio.sleep(3600)

    elif role == "joiner":
        bootstrap_addr = None
        with trio.fail_after(60.0):
            while not bootstrap_addr:
                bootstrap_addr = await trio.to_thread.run_sync(
                    r.get, f"{test_key}_bootstrap_addr"
                )
                if not bootstrap_addr:
                    await trio.sleep(0.5)
        logger.info(f"Bootstrapping from {bootstrap_addr}")

        info = info_from_p2p_addr(Multiaddr(bootstrap_addr))
        expected_id = info.peer_id

        # Real BootstrapDiscovery path: validate -> peerstore -> dial ->
        # reconnect loop. The joiner never dials manually; it observes the
        # connection the bootstrap module establishes.
        host = new_host(bootstrap=[bootstrap_addr])
        setup_ping_handler(host)
        async with host.run(listen_addrs=[listen_addr]):
            logger.info(f"Joiner started as {host.get_id().to_string()}")
            try:
                with trio.fail_after(60.0):
                    while expected_id not in host.get_network().connections:
                        await trio.sleep(0.5)
            except trio.TooSlowError:
                logger.error("Test Failed: bootstrap did not connect in time")
                print("error: bootstrap did not connect in time", flush=True)
                print("status: fail", flush=True)
                return 1

            logger.info("Bootstrap connection established, verifying with ping")
            try:
                with trio.fail_after(15.0):
                    stream = await host.new_stream(expected_id, [PING_PROTO])
                    await stream.write(b"ping")
                    resp = await stream.read(4)
                    await stream.close()
                    if resp == b"pong":
                        logger.info("Joiner pinged bootstrap node!")
                        print("status: pass", flush=True)
                        return 0
                    logger.error(f"Test Failed: Unexpected ping response: {resp}")
                    print(f"error: Unexpected ping response: {resp}", flush=True)
                    print("status: fail", flush=True)
                    return 1
            except Exception as e:
                logger.error(f"Test Failed: Ping over bootstrap conn failed: {e}")
                print(f"error: Ping over bootstrap conn failed: {e}", flush=True)
                print("status: fail", flush=True)
                return 1
    else:
        logger.error(f"Unknown role: {role}")
        return 1


if __name__ == "__main__":
    sys.exit(trio.run(main))
