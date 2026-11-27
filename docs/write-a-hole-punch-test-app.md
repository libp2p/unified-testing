# How to Write a Hole Punch Test Application

You want to write a new hole punch test do you? You've come to the correct place.
This document will describe exactly how to write an application and define a
Dockerfile so that it can be run by the `hole-punch` test in this repo.

## The Goals of These Hole Punch Tests

The `hole-punch` test (i.e. the test executed by the `hole-punch/run.sh` script)
seeks to measure the following:

1. DCUtR (Direct Connection Upgrade through Relay) success
2. NAT traversal capability
3. Direct connection establishment time

The hole punch tests verify that libp2p implementations can establish direct
peer-to-peer connections through NAT (Network Address Translation) devices using
the DCUtR protocol. The test framework creates realistic network topologies with
NAT routers and relay servers to simulate real-world scenarios where peers are
behind firewalls or NATs.

### Measuring DCUtR Success

The primary goal is to determine whether two peers behind separate NAT routers
can successfully establish a direct connection after initially connecting through
a relay server. The test is considered successful if:

1. Both peers successfully connect to the relay server
2. The DCUtR protocol successfully coordinates hole punching
3. A direct connection is established between the peers
4. Data can flow directly without going through the relay

### Measuring Direct Connection Time

To measure the connection establishment time, we record how long it takes from
when the DCUtR protocol starts until the direct connection is fully established
and verified. This timing includes:

- DCUtR protocol negotiation through the relay
- Simultaneous connection attempts from both peers
- NAT hole punching coordination
- Connection upgrade from relayed to direct

## Test Setup

The testing script executes the `hole-punch` test using Docker Compose. It
generates a `docker-compose.yaml` file for each test that creates a complex
network topology with **five containers**:

1. **Dialer Router** - NAT router for the dialer's LAN
2. **Listener Router** - NAT router for the listener's LAN
3. **Relay Server** - libp2p relay on the WAN network
4. **Dialer** - The peer initiating the connection (behind NAT)
5. **Listener** - The peer receiving the connection (behind NAT)

The network topology consists of:
- **WAN Network** (10.x.x.64/27) - Contains relay and NAT routers
- **Dialer LAN** (10.x.x.96/27) - Private network behind dialer's NAT
- **Listener LAN** (10.x.x.128/27) - Private network behind listener's NAT

Each test gets unique subnet IDs calculated from the test key to ensure complete
isolation between parallel tests.

### Example Generated `docker-compose.yaml`

```yaml
name: rust-v0_56_x_rust-v0_56__tcp__noise__yamux_

networks:
  wan-network:
    driver: bridge
    ipam:
      config:
        - subnet: 10.123.45.64/27
  dialer-lan-network:
    driver: bridge
    ipam:
      config:
        - subnet: 10.123.45.96/27
  listener-lan-network:
    driver: bridge
    ipam:
      config:
        - subnet: 10.123.45.128/27
  hole-punch-network:
    external: true

services:
  relay:
    image: hole-punch-rust-v0.56-relay
    container_name: rust-v0_56_x_rust-v0_56__tcp__noise__yamux__relay
    init: true
    networks:
      wan-network:
        ipv4_address: 10.123.45.68
      hole-punch-network:
    environment:
      - REDIS_ADDR=hole-punch-redis:6379
      - TEST_KEY=a5b50d5e
      - TRANSPORT=tcp
      - RELAY_IP=10.123.45.68
      - DIALER_LAN_SUBNET=10.123.45.96/27
      - DIALER_ROUTER_IP=10.123.45.66
      - LISTENER_LAN_SUBNET=10.123.45.128/27
      - LISTENER_ROUTER_IP=10.123.45.67
      - DEBUG=false
      - SECURE_CHANNEL=noise
      - MUXER=yamux

  dialer-router:
    image: hole-punch-linux-router
    container_name: rust-v0_56_x_rust-v0_56__tcp__noise__yamux__dialer_router
    init: true
    cap_add:
      - NET_ADMIN
    networks:
      wan-network:
        ipv4_address: 10.123.45.66
      dialer-lan-network:
        ipv4_address: 10.123.45.98
    environment:
      - WAN_IP=10.123.45.66
      - LAN_IP=10.123.45.98
      - LAN_SUBNET=10.123.45.96/27

  listener-router:
    image: hole-punch-linux-router
    container_name: rust-v0_56_x_rust-v0_56__tcp__noise__yamux__listener_router
    init: true
    cap_add:
      - NET_ADMIN
    networks:
      wan-network:
        ipv4_address: 10.123.45.67
      listener-lan-network:
        ipv4_address: 10.123.45.130
    environment:
      - WAN_IP=10.123.45.67
      - LAN_IP=10.123.45.130
      - LAN_SUBNET=10.123.45.128/27

  dialer:
    image: hole-punch-rust-v0.56
    container_name: rust-v0_56_x_rust-v0_56__tcp__noise__yamux__dialer
    depends_on:
      - relay
      - dialer-router
    networks:
      dialer-lan-network:
        ipv4_address: 10.123.45.99
      hole-punch-network:
    environment:
      - IS_DIALER=true
      - REDIS_ADDR=hole-punch-redis:6379
      - TEST_KEY=a5b50d5e
      - TRANSPORT=tcp
      - DIALER_IP=10.123.45.99
      - WAN_SUBNET=10.123.45.64/27
      - WAN_ROUTER_IP=10.123.45.98
      - DEBUG=false
      - SECURE_CHANNEL=noise
      - MUXER=yamux

  listener:
    image: hole-punch-rust-v0.56
    container_name: rust-v0_56_x_rust-v0_56__tcp__noise__yamux__listener
    depends_on:
      - relay
      - listener-router
    networks:
      listener-lan-network:
        ipv4_address: 10.123.45.131
      hole-punch-network:
    environment:
      - IS_DIALER=false
      - REDIS_ADDR=hole-punch-redis:6379
      - TEST_KEY=a5b50d5e
      - TRANSPORT=tcp
      - LISTENER_IP=10.123.45.131
      - WAN_SUBNET=10.123.45.64/27
      - WAN_ROUTER_IP=10.123.45.130
      - DEBUG=false
      - SECURE_CHANNEL=noise
      - MUXER=yamux
```

When `docker compose` is executed, it brings up all five containers with their
respective network configurations. There is a global Redis server already
running in the `hole-punch-network` and its address is passed to the relay and
both peers using the `REDIS_ADDR` environment variable.

## Test Execution

You will typically write three separate applications or modes:

1. **Relay Server** - Provides the relay functionality
2. **Peer (Dialer mode)** - Initiates the hole punch
3. **Peer (Listener mode)** - Responds to the hole punch

However, for peer implementations, you usually only need one application that
can function both as the `listener` and the `dialer` by checking the
`IS_DIALER` environment variable.

Please note that all logging and debug messages must be sent to stderr. The
stdout stream is *only* used for reporting the results in YAML format (for
dialer only).

The typical high-level flow for any `hole-punch` test application is as follows:

1. Your application reads the common environment variables:

   ```sh
   DEBUG=false                       # boolean value, either true or false
   IS_DIALER=true                    # boolean value, either true or false (not set for relay)
   REDIS_ADDR=hole-punch-redis:6379  # URL and port: hole-punch-redis:6379
   TEST_KEY=a5b50d5e                 # 8-character hexadecimal string
   TRANSPORT=tcp                     # transport name: tcp, quic-v1, ws, webrtc-direct, etc
   SECURE_CHANNEL=noise              # secure channel name: noise, tls
   MUXER=yamux                       # muxer name: yamux, mplex
   ```

   NOTE: The `SECURE_CHANNEL` and `MUXER` environment variables are not set when
   the `TRANSPORT` is a "standalone" transport such as "quic-v1", etc.

   NOTE: The `TEST_KEY` value is the first 8 hexadecimal characters of the sha256
   hash of the test name. This is used for namespacing the key(s) used when
   interacting with the global Redis server for coordination.

   NOTE: The `DEBUG` value is set to true when the test was run with `--debug`.
   This is to signal to the test applications to generate verbose logging for
   debug purposes.

2. The relay is a separate image, listed under `relays:` in
   `hole-punch/images.yaml`, so it always runs the `relay` code. A peer image
   runs the `dialer` code if `IS_DIALER` is true, else the `listener` code (see
   below).

### `relay` Application Flow

1. When your test application is run in `relay` mode, it will be passed the
   following environment variables:

   ```sh
   RELAY_IP=10.123.45.68
   DIALER_LAN_SUBNET=10.123.45.96/27
   DIALER_ROUTER_IP=10.123.45.66
   LISTENER_LAN_SUBNET=10.123.45.128/27
   LISTENER_ROUTER_IP=10.123.45.67
   ```

   The relay sits on the WAN network only, so before anything else it must add
   routes to both LAN subnets through their routers' WAN addresses. The
   container has `NET_ADMIN`, and the WAN interface is named `wan0`:

   ```sh
   ip route add "${DIALER_LAN_SUBNET}" via "${DIALER_ROUTER_IP}" dev wan0
   ip route add "${LISTENER_LAN_SUBNET}" via "${LISTENER_ROUTER_IP}" dev wan0
   ```

   The image needs `iproute2` for this. The rust relay does it in
   `hole-punch/images/rust/v0.56/run-relay.sh`.

2. Start the relay server and listen on the `RELAY_IP` address on the WAN
   network.

3. Calculate your relay multiaddr (e.g., `/ip4/10.123.45.68/tcp/4001/p2p/<peer-id>`).

4. Connect to the Redis server at `REDIS_ADDR` and set the value for the key
   `<TEST_KEY>_relay_multiaddr` to your relay multiaddr value.

   NOTE: The use of the `TEST_KEY` value in the key name effectively namespaces
   the key-value pair used for each test. Since we typically run multiple tests
   in parallel, this keeps the tests isolated from each other on the global
   Redis server.

5. Accept connections from both the dialer and listener peers.

6. Relay messages between the peers to facilitate DCUtR protocol negotiation.

7. The `relay` must run until it is shutdown by Docker. Don't worry about
   exiting logic. When the `dialer` exits, all containers are automatically
   shut down.

### `dialer` Application Flow

1. When your test application is run in `dialer` mode (peer behind NAT initiating
   the connection), it will be passed the following environment variables:

   ```sh
   IS_DIALER=true
   DIALER_IP=10.123.45.99
   WAN_SUBNET=10.123.45.64/27
   WAN_ROUTER_IP=10.123.45.98
   ```

   Each peer sits on its own LAN behind a NAT router, so before anything else
   it must route the WAN subnet through that router. The container has
   `NET_ADMIN`, and the LAN interface is named `lan0`:

   ```sh
   ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev lan0
   ```

   The image needs `iproute2` for this. The rust peer does it in
   `hole-punch/images/rust/v0.56/run-peer.sh`.

2. Start your libp2p node listening on `DIALER_IP`, not `0.0.0.0`: the peers
   are also both attached to `hole-punch-network` (interface `redis0`), a flat
   path with no NAT, and a connection over it would pass without punching
   anything. Configure your node to:
   - Enable the DCUtR protocol
   - Enable relay client functionality
   - Use the specified TRANSPORT, SECURE_CHANNEL, and MUXER

3. Connect to the Redis server at `REDIS_ADDR` and poll it for the value
   associated with the `<TEST_KEY>_relay_multiaddr` key.

4. Connect to the relay server using the multiaddr from Redis. Establish a
   relayed connection.

5. Connect to Redis again and poll for the value associated with the
   `<TEST_KEY>_listener_peer_id` key to get the listener's peer ID.

6. Start a timer, then initiate a connection to the listener through the relay
   (`<relay multiaddr>/p2p-circuit/p2p/<listener peer id>`). The timer covers
   the circuit dial and the whole DCUtR upgrade.

7. The DCUtR protocol should automatically attempt to establish a direct
   connection by:
   - Exchanging address information through the relay
   - Simultaneously attempting connections from both sides
   - Performing NAT hole punching

8. Wait for the direct connection to be established. Verify that the connection
   is direct (not relayed).

9. Stop the timer when the direct connection is established.

10. Send a ping over the direct connection and record its round-trip time. The
    results are reported only once this ping succeeds.

11. Print to stdout the results in YAML format (see the section "Results
    Schema" below).

12. Exit cleanly with an exit code of 0. If there are any errors (connection
    timeout, DCUtR failure, etc.), exit with a non-zero exit code to signal
    test failure.

### `listener` Application Flow

1. When your test application is run in `listener` mode (peer behind NAT waiting
   for incoming connection), it will be passed the following environment
   variables:

   ```sh
   IS_DIALER=false
   LISTENER_IP=10.123.45.131
   WAN_SUBNET=10.123.45.64/27
   WAN_ROUTER_IP=10.123.45.130
   ```

   Each peer sits on its own LAN behind a NAT router, so before anything else
   it must route the WAN subnet through that router. The container has
   `NET_ADMIN`, and the LAN interface is named `lan0`:

   ```sh
   ip route add "${WAN_SUBNET}" via "${WAN_ROUTER_IP}" dev lan0
   ```

   The image needs `iproute2` for this. The rust peer does it in
   `hole-punch/images/rust/v0.56/run-peer.sh`.

2. Start your libp2p node listening on `LISTENER_IP`. Configure your node to:
   - Enable the DCUtR protocol
   - Enable relay client functionality
   - Use the specified TRANSPORT, SECURE_CHANNEL, and MUXER

3. Connect to the Redis server at `REDIS_ADDR` and set the value for the key
   `<TEST_KEY>_listener_peer_id` to your peer ID value.

4. Connect to Redis again and poll for the value associated with the
   `<TEST_KEY>_relay_multiaddr` key to get the relay's multiaddr.

5. Connect to the relay server. Establish a relayed connection and register with
   the relay so that you can be reached.

6. Wait for the dialer to initiate a connection through the relay.

7. When the DCUtR protocol starts (initiated by the dialer), your node should:
   - Exchange address information through the relay
   - Simultaneously attempt a connection to the dialer
   - Perform NAT hole punching from your side

8. Wait for the direct connection to be established. Your libp2p implementation
   should automatically upgrade from the relayed connection to the direct
   connection.

9. Respond to any ping or verification messages from the dialer over the direct
   connection.

10. The `listener` must run until it is shutdown by Docker. Don't worry about
    exiting logic. When the `dialer` exits, the `listener` container is
    automatically shut down.

## Results Schema

To report the results of the `hole-punch` test in a way that the test scripts
understand, your test application must output the results in YAML format by
printing it to stdout (dialer only). The `hole-punch` scripts read the stdout
from the `dialer` and save it into a per-test results.yaml file for later
consolidation into the global results.yaml file for the full test run.

Below is an example of a valid results report printed to stdout:

```yaml
latency:
  handshake_plus_one_rtt: 1234.56
  ping_rtt: 12.34
  unit: ms
```

- `handshake_plus_one_rtt`: the timer from step 6 of the `dialer` flow (circuit
  dial through the direct connection being established) plus `ping_rtt`.
- `ping_rtt`: the round-trip time of one ping over the direct connection.
- `unit`: always `ms`.

`hole-punch/lib/run-single-test.sh` keeps only the `latency:` line and the
three keys under it, indented by exactly two spaces. Any other stdout line is
dropped, so a differently named key is lost without an error and the test still
passes on its exit code alone.

NOTE: The `hole-punch/lib/run-single-test.sh` script handles adding the metadata
for the results file in each test. It writes out something like the following
and then appends the data your test application writes to stdout after it:

```yaml
test: rust-v0.56 x rust-v0.56 (tcp, noise, yamux) [dr: linux, rly: rust-v0.56, lr: linux]
dialer: rust-v0.56
listener: rust-v0.56
dialerRouter: linux
listenerRouter: linux
relay: rust-v0.56
transport: tcp
secureChannel: noise
muxer: yamux
status: pass
```

NOTE: the `status` value of `pass` or `fail` is determined by the exit code of
your test application in `dialer` mode. If that exits with '0' then `status`
will be set to `pass` and the test will be reported as passing. Any other value
will cause `status` to be set to `fail` and the test will be reported as
failing.

## Network Configuration Details

### Subnet Calculation

Each test calculates unique subnet IDs from the TEST_KEY to avoid collisions:

```
SUBNET_ID_1 = (first 2 hex chars of TEST_KEY as int % 224) + 32
SUBNET_ID_2 = (next 2 hex chars of TEST_KEY as int % 224) + 32

WAN_SUBNET = 10.SUBNET_ID_1.SUBNET_ID_2.64/27
DIALER_LAN_SUBNET = 10.SUBNET_ID_1.SUBNET_ID_2.96/27
LISTENER_LAN_SUBNET = 10.SUBNET_ID_1.SUBNET_ID_2.128/27
```

This ensures that even with many parallel tests, each gets isolated networks
that don't conflict.

### Static IP Assignments

Each container gets a specific IP address within its network:

- **Relay**: 10.x.x.68 (on WAN)
- **Dialer Router WAN**: 10.x.x.66 (on WAN)
- **Dialer Router LAN**: 10.x.x.98 (on Dialer LAN)
- **Dialer Peer**: 10.x.x.99 (on Dialer LAN)
- **Listener Router WAN**: 10.x.x.67 (on WAN)
- **Listener Router LAN**: 10.x.x.130 (on Listener LAN)
- **Listener Peer**: 10.x.x.131 (on Listener LAN)

### NAT Configuration

The NAT routers are configured with iptables to:
- Enable IP forwarding between WAN and LAN interfaces
- Perform SNAT (Source NAT) on outgoing packets
- Allow established and related connections back through

This simulates realistic NAT behavior that the DCUtR protocol must traverse.

## Important Notes

1. **Network Isolation**: Each test runs in completely isolated Docker networks.
   Your application should not make any assumptions about other tests running
   concurrently.

2. **Default Routes**: The peer containers have their default route set to their
   respective NAT routers, so all traffic to the WAN goes through the NAT.

3. **Relay Discovery**: Both peers must discover the relay through Redis before
   they can connect to it.

4. **Peer Discovery**: The dialer must discover the listener's peer ID through
   Redis before initiating the connection.

5. **DCUtR Protocol**: The actual hole punching is handled by your libp2p
   implementation's DCUtR protocol. Your application just needs to trigger it
   by attempting to connect to a peer behind NAT while you're also behind NAT.

6. **Timing**: The handshake time measurement should include the entire DCUtR
   process but not the initial relay connection setup time.

7. **Verification**: It's important to verify that the final connection is
   actually direct and not still going through the relay. Your libp2p
   implementation should provide a way to check this.
