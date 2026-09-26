import logging
import os
import socket
import sys
import redis
import trio
from multiaddr import Multiaddr
from libp2p import new_host
from libp2p.peer.peerinfo import info_from_p2p_addr, PeerInfo
from libp2p.peer.id import ID as PeerID
from libp2p.custom_types import TProtocol
from libp2p.discovery.rendezvous.service import RendezvousService
from libp2p.discovery.rendezvous.client import RendezvousClient

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
        sys.exit(1)

    redis_host, redis_port = redis_addr.split(":")
    r = redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)

    def get_container_ip() -> str:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((redis_host, int(redis_port)))
        ip = s.getsockname()[0]
        s.close()
        return ip
        
    container_ip = await trio.to_thread.run_sync(get_container_ip)
    
    host = new_host()
    setup_ping_handler(host)
    listen_addr = Multiaddr(f"/ip4/{container_ip}/tcp/0")

    async with host.run(listen_addrs=[listen_addr]):
        addrs = host.get_addrs()
        while not addrs:
            await trio.sleep(0.1)
            addrs = host.get_addrs()

        port = addrs[0].value_for_protocol("tcp")
        my_multiaddr = f"/ip4/{container_ip}/tcp/{port}/p2p/{host.get_id().to_string()}"
        logger.info(f"Node started in role '{role}' at {my_multiaddr}")

        if role == "server":
            _ = RendezvousService(host)
            server_key = f"{test_key}_server_addr"
            await trio.to_thread.run_sync(r.set, server_key, my_multiaddr)
            logger.info("Rendezvous server waiting indefinitely...")
            while True:
                await trio.sleep(3600)

        elif role == "registrant":
            server_key = f"{test_key}_server_addr"
            server_addr = None
            with trio.fail_after(60.0):
                while not server_addr:
                    server_addr = await trio.to_thread.run_sync(r.get, server_key)
                    if not server_addr:
                        await trio.sleep(0.5)

            server_info = info_from_p2p_addr(Multiaddr(server_addr))
            with trio.fail_after(30.0):
                await host.connect(server_info)

            client = RendezvousClient(host, server_info.peer_id)
            ns = f"rendezvous-ns-{test_key}"
            granted_ttl = await client.register(ns, 300)
            logger.info(f"Registrant registered with TTL {granted_ttl}")

            await trio.to_thread.run_sync(r.set, f"{test_key}_registrant_id", host.get_id().to_string())
            await trio.to_thread.run_sync(r.set, f"{test_key}_registrant_done", "1")
            logger.info("Registrant waiting indefinitely for discoverer...")
            while True:
                await trio.sleep(3600)

        elif role == "discoverer":
            server_key = f"{test_key}_server_addr"
            registrant_done_key = f"{test_key}_registrant_done"
            server_addr = None
            registrant_done = None

            with trio.fail_after(60.0):
                while not (server_addr and registrant_done):
                    if not server_addr:
                        server_addr = await trio.to_thread.run_sync(r.get, server_key)
                    if not registrant_done:
                        registrant_done = await trio.to_thread.run_sync(r.get, registrant_done_key)
                    if not (server_addr and registrant_done):
                        await trio.sleep(0.5)

            expected_id = await trio.to_thread.run_sync(r.get, f"{test_key}_registrant_id")
            server_info = info_from_p2p_addr(Multiaddr(server_addr))
            with trio.fail_after(30.0):
                await host.connect(server_info)

            client = RendezvousClient(host, server_info.peer_id)
            ns = f"rendezvous-ns-{test_key}"
            peers, _ = await client.discover(ns)
            logger.info(f"Discoverer found {len(peers)} peer(s)")

            target_peer = None
            for p in peers:
                if p.peer_id.to_string() == expected_id:
                    target_peer = p
                    break

            if not target_peer:
                logger.error(f"Test Failed: Expected registrant peer {expected_id} not found in discovery")
                print(f"error: Registrant peer {expected_id} not found in discovery", flush=True)
                print("status: fail", flush=True)
                return 1

            # Dial target peer on PingProto
            try:
                with trio.fail_after(10.0):
                    await host.connect(target_peer)
                    stream = await host.new_stream(target_peer.peer_id, [PING_PROTO])
                    await stream.write(b"ping")
                    resp = await stream.read(4)
                    await stream.close()
                    if resp == b"pong":
                        logger.info("Discoverer successfully pinged registrant peer!")
                        print("status: pass", flush=True)
                        return 0
                    else:
                        logger.error(f"Test Failed: Unexpected ping response: {resp}")
                        print(f"error: Unexpected ping response: {resp}", flush=True)
                        print("status: fail", flush=True)
                        return 1
            except Exception as e:
                logger.error(f"Test Failed: Dial to registrant peer failed: {e}")
                print(f"error: Dial to registrant peer failed: {e}", flush=True)
                print("status: fail", flush=True)
                return 1
        else:
            logger.error(f"Unknown role: {role}")
            return 1

if __name__ == "__main__":
    sys.exit(trio.run(main))
