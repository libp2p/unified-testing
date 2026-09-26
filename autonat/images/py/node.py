import logging
import os
import socket
import sys

import redis
import trio
from multiaddr import Multiaddr

from libp2p import new_host
from libp2p.host.autonat.autonat import AUTONAT_PROTOCOL_ID
from libp2p.host.autonat.pb.autonat_pb2 import Message
from libp2p.peer.id import ID
from libp2p.peer.peerinfo import PeerInfo, info_from_p2p_addr
from libp2p.utils.varint import encode_varint_prefixed, read_varint_prefixed_bytes

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)


def getenv(name: str, default: str | None = None) -> str:
    val = os.environ.get(name, default)
    if val is None:
        logger.error(f"Missing required environment variable: {name}")
        sys.exit(1)
    return val


async def handle_autonat_stream(host, stream) -> None:
    """Serve /libp2p/autonat/1.0.0: read a DIAL request, dial the requester
    back on its advertised addresses, and report the outcome."""
    try:
        request_bytes = await read_varint_prefixed_bytes(stream)
        request = Message()
        request.ParseFromString(request_bytes)

        response = Message()
        response.type = Message.DIAL_RESPONSE

        if request.type == Message.DIAL:
            peer_id = ID(request.dial.peer.id)
            addrs = [Multiaddr(a) for a in request.dial.peer.addrs]
            try:
                await host.connect(PeerInfo(peer_id, addrs))
                response.dialResponse.status = Message.OK
                if addrs:
                    response.dialResponse.addr = bytes(addrs[0])
                logger.info(f"Dial-back to {peer_id} succeeded")
            except Exception as e:
                response.dialResponse.status = Message.E_DIAL_ERROR
                response.dialResponse.statusText = f"dial-back failed: {e}"
                logger.warning(f"Dial-back to {peer_id} failed: {e}")
        else:
            response.dialResponse.status = Message.E_DIAL_ERROR
            response.dialResponse.statusText = "unexpected message type"

        await stream.write(encode_varint_prefixed(response.SerializeToString()))
    except Exception as e:
        logger.error(f"Error handling AutoNAT stream: {e}")
    finally:
        await stream.close()


async def run_server(r: redis.Redis, test_key: str, container_ip: str) -> int:
    host = new_host()
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{container_ip}/tcp/0")]):
        host.set_stream_handler(
            AUTONAT_PROTOCOL_ID,
            lambda stream: handle_autonat_stream(host, stream),
        )

        addrs = host.get_addrs()
        while not addrs:
            await trio.sleep(0.1)
            addrs = host.get_addrs()
        port = addrs[0].value_for_protocol("tcp")
        my_multiaddr = f"/ip4/{container_ip}/tcp/{port}/p2p/{host.get_id().to_string()}"
        logger.info(f"AutoNAT server ready at {my_multiaddr}")

        await trio.to_thread.run_sync(r.set, f"{test_key}_server_addr", my_multiaddr)
        while True:
            await trio.sleep(3600)
    return 0


async def run_client(r: redis.Redis, test_key: str, container_ip: str) -> int:
    def fail(msg: str) -> int:
        logger.error(msg)
        print(f"error: {msg}", flush=True)
        return 1

    host = new_host()
    async with host.run(listen_addrs=[Multiaddr(f"/ip4/{container_ip}/tcp/0")]):
        addrs = host.get_addrs()
        while not addrs:
            await trio.sleep(0.1)
            addrs = host.get_addrs()

        server_addr = None
        with trio.fail_after(60.0):
            while not server_addr:
                server_addr = await trio.to_thread.run_sync(
                    r.get, f"{test_key}_server_addr"
                )
                if not server_addr:
                    await trio.sleep(0.5)

        server_info = info_from_p2p_addr(Multiaddr(server_addr))
        with trio.fail_after(30.0):
            await host.connect(server_info)
        logger.info(f"Connected to AutoNAT server {server_info.peer_id}")

        # Ask the server to dial us back on our advertised listen addrs.
        request = Message()
        request.type = Message.DIAL
        request.dial.peer.id = host.get_id().to_bytes()
        for addr in host.get_addrs():
            request.dial.peer.addrs.append(addr.to_bytes())

        try:
            with trio.fail_after(30.0):
                stream = await host.new_stream(
                    server_info.peer_id, [AUTONAT_PROTOCOL_ID]
                )
                await stream.write(encode_varint_prefixed(request.SerializeToString()))
                response_bytes = await read_varint_prefixed_bytes(stream)
                await stream.close()
        except Exception as e:
            return fail(f"AutoNAT exchange failed: {e}")

        response = Message()
        response.ParseFromString(response_bytes)
        if response.type != Message.DIAL_RESPONSE:
            return fail(f"Unexpected response type: {response.type}")

        status = response.dialResponse.status
        addr = response.dialResponse.addr
        logger.info(f"Server verdict: status={status} addr={addr!r}")
        print(f"verdict: {status}", flush=True)

        if status == Message.OK:
            logger.info("AutoNAT dial-back succeeded: node is reachable")
            print("status: pass", flush=True)
            return 0
        return fail(
            f"Server could not dial us back "
            f"(status={status} statusText={response.dialResponse.statusText!r})"
        )


async def amain() -> int:
    role = getenv("ROLE")
    redis_addr = getenv("REDIS_ADDR")
    test_key = getenv("TEST_KEY")

    redis_host, redis_port = redis_addr.split(":")
    r = redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)

    def get_container_ip() -> str:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((redis_host, int(redis_port)))
        ip = s.getsockname()[0]
        s.close()
        return ip

    container_ip = await trio.to_thread.run_sync(get_container_ip)

    try:
        if role == "server":
            return await run_server(r, test_key, container_ip)
        elif role == "client":
            return await run_client(r, test_key, container_ip)
        else:
            logger.error(f"Unknown role: {role}")
            return 1
    except Exception as e:
        logger.exception(f"Test failed: {e}")
        print(f"error: {e}", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(trio.run(amain))
