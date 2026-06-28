import logging
import os
import socket
import sys
import redis
import trio
from libp2p import new_host
from libp2p.crypto.rsa import create_new_key_pair
from libp2p.tools.utils import info_from_p2p_addr
from libp2p.kad_dht.kad_dht import DHTMode, KadDHT
from libp2p.tools.async_service.trio_service import background_trio_service
from libp2p.records.validator import Validator
from multiaddr import Multiaddr

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

class TestValidator(Validator):
    def validate(self, key: str, value: bytes) -> None:
        pass
    def select(self, key: str, values: list[bytes]) -> int:
        return 0

async def main() -> None:
    role = os.environ.get("ROLE")
    redis_addr = os.environ.get("REDIS_ADDR")
    test_key = os.environ.get("TEST_KEY")
    
    if not all([role, redis_addr, test_key]):
        logger.error("Missing required environment variables")
        sys.exit(1)

    redis_host, redis_port = redis_addr.split(":")
    r = redis.Redis(host=redis_host, port=int(redis_port), decode_responses=True)
    
    # Create libp2p host synchronously
    key_pair = create_new_key_pair()
    host = new_host(key_pair=key_pair)
    
    # Determine container IP without blocking the async loop
    def get_container_ip() -> str:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((redis_host, int(redis_port)))
        ip = s.getsockname()[0]
        s.close()
        return ip
        
    container_ip = await trio.to_thread.run_sync(get_container_ip)

    # Run host with trio context manager
    listen_addrs = [Multiaddr(f"/ip4/{container_ip}/tcp/0")]
    async with host.run(listen_addrs=listen_addrs), trio.open_nursery() as nursery:
        nursery.start_soon(host.get_peerstore().start_cleanup_task, 60)
        
        addrs = host.get_addrs()
        while not addrs:
            await trio.sleep(0.1)
            addrs = host.get_addrs()

        port = addrs[0].value_for_protocol("tcp")
        my_multiaddr = f"/ip4/{container_ip}/tcp/{port}/p2p/{host.get_id().to_string()}"
        logger.info(f"Node started at {my_multiaddr}")

        if role == "bootstrap":
            bootstrap_key = f"{test_key}_bootstrap_addr"
            await trio.to_thread.run_sync(r.set, bootstrap_key, my_multiaddr)
            logger.info("Bootstrap node waiting indefinitely...")
            
            dht = KadDHT(host, DHTMode.SERVER)
            dht.register_validator("example", TestValidator())
            async with background_trio_service(dht):
                while True:
                    await trio.sleep(3600)
                
        elif role == "provider":
            bootstrap_key = f"{test_key}_bootstrap_addr"
            bootstrap_addr = None
            with trio.fail_after(60.0):
                while not bootstrap_addr:
                    bootstrap_addr = await trio.to_thread.run_sync(r.get, bootstrap_key)
                    if not bootstrap_addr:
                        await trio.sleep(0.5)
            
            maddr = Multiaddr(bootstrap_addr)
            info = info_from_p2p_addr(maddr)
            
            with trio.fail_after(30.0):
                await host.connect(info)
            
            dht = KadDHT(host, DHTMode.SERVER)
            dht.register_validator("example", TestValidator())
            async with background_trio_service(dht):
                logger.info("Test 1: Provider announcing key 'interop-test-key'...")
                try:
                    await dht.provide("interop-test-key")
                    logger.info("Test 1 -> Success")
                except Exception as e:
                    logger.error(f"Test 1 FAILED: Could not announce provider: {e}")
                    raise
                
                logger.info("Test 3: Provider putting value for '/example/data'...")
                try:
                    await dht.put_value("/example/data", b"hello from py client")
                    logger.info("Test 3 -> Success")
                except Exception as e:
                    logger.error(f"Test 3 FAILED: Could not put value: {e}")
                    raise
                
                provider_done_key = f"{test_key}_provider_done"
                await trio.to_thread.run_sync(r.set, provider_done_key, "done")
                
                while True:
                    await trio.sleep(3600)
                
        elif role == "querier":
            bootstrap_key = f"{test_key}_bootstrap_addr"
            bootstrap_addr = None
            with trio.fail_after(60.0):
                while not bootstrap_addr:
                    bootstrap_addr = await trio.to_thread.run_sync(r.get, bootstrap_key)
                    if not bootstrap_addr:
                        await trio.sleep(0.5)
                    
            provider_done_key = f"{test_key}_provider_done"
            provider_done = None
            with trio.fail_after(60.0):
                while not provider_done:
                    provider_done = await trio.to_thread.run_sync(r.get, provider_done_key)
                    if not provider_done:
                        await trio.sleep(0.5)
                
            maddr = Multiaddr(bootstrap_addr)
            info = info_from_p2p_addr(maddr)
            
            with trio.fail_after(30.0):
                await host.connect(info)
            
            dht = KadDHT(host, DHTMode.CLIENT)
            dht.register_validator("example", TestValidator())
            found = False
            async with background_trio_service(dht):
                logger.info("Test 2: Querier searching for key 'interop-test-key'...")
                providers = await dht.find_providers("interop-test-key")
                
                found = bool(providers)
                if found:
                    logger.info(f"Test 2 -> Success! Found {len(providers)} provider(s)!")
                    
                    logger.info("Test 4: Querier getting value for '/example/data'...")
                    try:
                        value = await dht.get_value("/example/data")
                        if value == b"hello from py client":
                            logger.info("Test 4 -> Success! Retrieved exact value: 'hello from py client'")
                            print("status: pass")
                        else:
                            logger.error(f"Test Failed: Expected 'hello from py client', but got {value}")
                            print(f"error: Expected 'hello from py client', but got {value}")
                            print("status: fail")
                            found = False
                    except Exception as e:
                        logger.error(f"Test Failed: Exception during get_value: {e}")
                        print(f"error: Exception during get_value: {e}")
                        print("status: fail")
                        found = False
                else:
                    logger.error("Test Failed: No providers found in DHT for key 'interop-test-key'")
                    print("error: No providers found in DHT for key 'interop-test-key'")
                    print("status: fail")
                    
                nursery.cancel_scope.cancel()
            
            if not found:
                sys.exit(1)
        else:
            logger.error(f"Unknown role: {role}")
            sys.exit(1)

if __name__ == "__main__":
    trio.run(main)
