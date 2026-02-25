# How to Write a Transport Test Application

You want to write a new transport test do you? You've come to the correct place.
This document will describe exactly how to write an application and define a
Dockerfile so that it can be run by the `transport` test in this repo.

## The Goals of These Transport Tests

The `transport` test (i.e. the test executed by the `transport/run.sh` script)
seeks to measure the following:

1. Dial success
2. Handshake latency
3. Ping latency

Currently, the test framework runs both the dialer and the listener
applications on the same host and docker network. 

### Measuring dial success

This is trivial, if the dialer successfully handshakes, then it successfully
dialed the listener. The exit status of the test reflects the success of the
dial operation. If the dial fails, then the test is marked as failed.

### Measuring the Latency

To measure the latency, we calculate the time to complete the handshake and
also record the ping latency measurement.

## Test Setup

The testing script executes the `transport` test using Docker Compose. It
generates a `docker-compose.yaml` file for each test. The `docker-compose.yaml`
file passes to the `listener` and `dialer` a set of environment variables that
they will use to know how to execute the test.

### Example Generated `docker-compose.yaml`

```yaml
name: rust-v0_56_x_rust-v0_56__quic-v1_

networks:
  transport-network:
    external: true

services:
  listener:
    image: transport-rust-v0.56
    container_name: rust-v0_56_x_rust-v0_56__quic-v1__listener
    init: true
    networks:
      - transport-network
    environment:
      - IS_DIALER=false
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=a5b50d5e
      - TRANSPORT=quic-v1
      - LISTENER_IP=0.0.0.0
      - DEBUG=false

  dialer:
    image: transport-rust-v0.56
    container_name: rust-v0_56_x_rust-v0_56__quic-v1__dialer
    depends_on:
      - listener
    networks:
      - transport-network
    environment:
      - IS_DIALER=true
      - REDIS_ADDR=transport-redis:6379
      - TEST_KEY=a5b50d5e
      - TRANSPORT=quic-v1
      - LISTENER_IP=0.0.0.0
      - DEBUG=false
```

When `docker compose` is executed, it brings up the `listener` and `dialer`
docker images and attaches them to the `transport-network` that has already been
created in the "start global services" step of the test pass. There is a global
Redis server already running in the `transport-network` and its address is passed to
both services using the `REDIS_ADDR` environment variable. Both services are
assigned an IP address dynamically and both have access to the DNS server
running in the network; that is how `transport-redis` resolution happens.

## Test Execution

Typically you only need to write one application that can function both as the
`listener` and the `dialer`. The `dialer` is responsible for connecting to the
listener and running the ping protocol with the listener. 

Please note that all logging and debug messages must be send to stderr. The
stdout stream is *only* used for reporting the results in YAML format.

The typical high-level flow for any `transport` test application is as follows:

1. Your application reads the common environment variables:

   ```sh
   DEBUG=false                  # boolean value, either true or false
   IS_DIALER=true               # boolean value, either true or false
   REDIS_ADDR=transport-redis:6379   # URL and port: transport-redis:6379
   TEST_KEY=a5b50d5e            # 8-character hexidecimal string
   TRANSPORT=tcp                # transport name: tcp, quic-v2, ws, webrtc, etc
   SECURE_CHANNEL=noise         # secure channel name: noise, tls
   MUXER=yamux                  # muxer name: yamux, noise
   ```

   NOTE: The `SECURE_CHANNEL` and `MUXER` environment variables are not set when
   the `TRANSPORT` is a "standalone" transport such as "quic-v1", etc.

   NOTE: The `TEST_KEY` value is the first 8 hexidecimal characters of the sha2
   256 hash of the test name. This is used for namespacing the key(s) used when
   interacting with the global redis server for coordination.

   NOTE: The `DEBUG` value is set to true when the test was run with `--debug`.
   This is to signal to the test applications to generate verbose logging for
   debug purposes.

2. If `IS_DIALER` is true, run the `dialer` code, else, run the `listener` code
   (see below).

### `dialer` Application Flow

1. When your test application is run in `dialer` mode, there are no other
   environment variables needed.

2. Connect to the Redis server at `REDIS_ADDR` and poll it asking for the value
   associated with the `<TEST_KEY>_listener_multiaddr` key.

3. Dial the `listener` at the multiaddr you received from the Redis server.

4. Calculate the time it took to dial, connect, and complete the handshake with the `listener`.

5. Handle the ping protocol responses and record the round trip latency.

6. Print to stdout, the results in YAML format (see the section "Results
   Schema" below).

7. Exit cleanly with an exit code of 0. If there are any errors, exit with a
   non-zero exit code to signal test failure.

### `listener` Application Flow

1. When your test application is run in `listener` mode, it will be passed the
   following environment variables that are unique to the `listener`. Your
   application must read these as well:

   ```sh
   LISTENER_IP=0.0.0.0
   ```

   NOTE: The `LISTENER_IP` is somewhat historical and is always set to
   `0.0.0.0` to get the test application to bind to all interfaces. it is up to
   your application to detect the non-localhost interface your application is
   bound to so that it can properly calculate its address to send to Redis.

2. Listen on the non-localhost network interface and calculate your multiaddr.

3. Connect to the Redis server at the `REDIS_ADDR` location and set the value
   for the key `<TEST_KEY>_listener_multiaddr` to your multiaddr value.

   NOTE: The use of the `TEST_KEY` value in the key name effectively namespaces
   the key-value pair used for each test. Since we typically run multiple tests
   in parallel, this keeps the tests isolated from each other on the global
   Redis server.

4. Run the event loop so that libp2p can complete the handshake and the ping
   protocol runs.

5. The `listener` must run until it is shutdown by Docker. Don't worry about
   exiting logic. When the `dialer` exits, the `listener` container is
   automatically shut down.

## Results Schema

To report the results of the `transport` test in a way that the test scripts
understand, your test application must output the results of the handshake
latency and the ping latency in YAML format by simply printing it to stdout.
The `transport` scripts read the stdout from the `dialer` and save it into a
per-test results.yaml file for later consolidation into the global results.yaml
file for the full test run.

Below is an example of a valid results report printed to stdout:

```yaml
# Measurements from dialer
latency:
  handshake_plus_one_rtt: 5.011
  ping_rtt: 0.599
  unit: ms
```

NOTE: The `transport/lib/run-signle-test.sh` script handles adding the metadata
for the results file in each test. It writes out something like the following
and then appends the data your test application writes to stdout after it:

```yaml
test: rust-v0.56 x rust-v0.56 (quic-v1)
dialer: rust-v0.56
listener: rust-v0.56
transport: quic-v1
secureChannel: null
muxer: null
status: pass
duration: 1
```

NOTE: the `status` value of `pass` or `fail` is determined by the exit code of
your test application in `dialer` mode. If that exits with '0' then `status`
will be set to `pass` and the test will be reported as passing. Any other value
will cause `status` to be set to `fail` and the test will be reported as
failing.

---

## How to Write a Misc (Protocol) Test Application

The `misc/` suite reuses the same Docker-Compose-based framework as `transport/`
but adds a sixth dimension: **protocol**. Your test application must be able to
act as either the dialer *or* the listener for the following application
protocols as selected by the `MISC_PROTOCOL` environment variable.

### Common Environment Variables

In addition to the [standard environment variables](#your-application-reads-the-common-environment-variables)
shared with the transport suite, the misc suite sets:

```sh
MISC_PROTOCOL=echo  # protocol to exercise: "ping", "echo", or "identify"
```

### Protocol: `ping` (`/ping/1.0.0`)

The ping protocol is the simplest possible liveness check.

**Minimum requirements:**

1. The dialer opens a stream using the `/ping/1.0.0` protocol.
2. The dialer sends exactly **32 bytes** of cryptographically random data.
3. The listener echoes back exactly those 32 bytes.
4. The dialer verifies the response is byte-for-byte identical.
5. Repeat for **5 round trips**. Each must succeed.
6. Exit with `0` on success, non-zero on failure.

### Protocol: `echo` (`/echo/1.0.0`)

Echo tests that arbitrary-length payloads are returned intact.

**Minimum requirements:**

1. The dialer opens a stream using the `/echo/1.0.0` protocol.
2. The dialer sends three probes in sequence:

   | Probe | Size | Content |
   |---|---|---|
   | 1 | 1 byte | `0x42` |
   | 2 | 256 bytes | repeating `0xAB` |
   | 3 | 4 096 bytes | repeating `0xCD` |

3. After sending each probe, the dialer reads back the same number of bytes and
   verifies the response is **byte-for-byte identical** to what was sent.
4. All three probes must pass on the same open stream (do not close between probes).
5. Exit with `0` on success, non-zero on failure.

**Listener side:** Copy each received byte back to the writer until the stream is
reset. No size prefix or framing is needed.

### Protocol: `identify` (`/id/1.0.0`)

Identify validates that a peer correctly advertises its metadata. Only the dialer
does active verification; the listener just needs to have the identify protocol
mounted.

**Minimum requirements for the dialer (verifier):**

After establishing a connection to the listener, dial the `/id/1.0.0` stream and
parse the `Identify` protobuf. Then assert:

| Field | Requirement |
|---|---|
| `protocolVersion` | Non-empty string |
| `publicKey` | Non-empty bytes; must match the Peer ID of the connection |
| `listenAddrs` | At least one address |
| `protocols` | Non-empty list; **must** include `/ping/1.0.0` |
| `observedAddr` | Optional — may be empty |

Exit with `0` if all assertions pass, non-zero otherwise. Log each failure reason
to stderr.

### Results Schema (Misc)

The misc dialer writes a minimal YAML status line to stdout:

```yaml
status: pass
protocols_tested:
  - echo
```

The `misc/lib/run-single-test.sh` script prepends the standard metadata block
(test name, dialer/listener IDs, transport, secureChannel, muxer, protocol) and
appends the data your dialer writes to stdout.

### Example Dockerfile

Your single Docker image should handle all three protocols. The simplest
structure is a conditional dispatch on `MISC_PROTOCOL`:

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm ci --omit=dev
COPY . ./
ENTRYPOINT ["node", "index.js"]
```

```js
// index.js (sketch)
const protocol = process.env.MISC_PROTOCOL
if (process.env.IS_DIALER === 'true') {
  if (protocol === 'ping')     await runPingDialer()
  else if (protocol === 'echo')     await runEchoDialer()
  else if (protocol === 'identify') await runIdentifyDialer()
} else {
  await startListener() // mounts all protocol handlers
}
```


