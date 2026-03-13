# Misc Protocol Interoperability Tests

A catch-all test suite that validates **application-level libp2p protocols** —
Ping, Echo, and Identify — across multiple implementations and transport
combinations.

## Why This Suite Exists

The [transport](../transport) suite answers *"can implementations connect and
exchange data?"* The misc suite goes one level higher and asks *"once connected,
do protocol-level semantics work correctly?"*

| Protocol | What is tested |
|----------|----------------|
| `/ping/1.0.0` | Round-trip latency; basic dial + stream lifecycle |
| `/echo/1.0.0` | Bidirectional stream payload integrity (write → read → compare) |
| `/identify/1.0.0` | Peer metadata exchange (protocol list, public key, observed addrs) |

This suite is also the designed home for future protocol validations that do
not need a dedicated top-level runner (e.g. Rendezvous, Request-Response,
Bitswap).

## Implementations Tested

| ID | Language | Protocols |
|----|----------|-----------|
| `js-v3.x` | JavaScript (Node.js, js-libp2p v3) | ping, echo, identify |
| `go-v0.45` | Go (go-libp2p v0.45) | ping |
| `rust-v0.56` | Rust (rust-libp2p v0.56) | ping |
| `python-v0.x` | Python (py-libp2p) | ping |

> **Note:** Go, Rust, and Python currently support `ping` only via their
> existing interop test images.  Echo and Identify support for those
> implementations — including dedicated Dockerfiles — will be added in
> follow-up PRs.

## Protocol Selection

The key differentiator from other test suites is the `--protocol-select` /
`--protocol-ignore` pair, which follows the same alias + inversion syntax
used for every other dimension:

```bash
# Run only echo tests
./run.sh --protocol-select "echo"

# Run everything except identify
./run.sh --protocol-ignore "identify"

# Run ping and echo
./run.sh --protocol-select "ping|echo"

# Inversion alias: run everything that is NOT echo
./run.sh --protocol-ignore "!~echo"
```

## Running Tests

### Prerequisites

```bash
./run.sh --check-deps
```

Required: `bash 4.0+`, `docker 20.10+`, `yq 4.0+`, `docker compose`, and the
UNIX standard utilities listed in [lib/check-dependencies.sh](../lib/check-dependencies.sh).

### Basic Usage

```bash
# Run all selected tests (prompts for confirmation)
./run.sh

# Skip the confirmation prompt
./run.sh -y

# Run only JS ↔ JS ping + echo tests
./run.sh --impl-select "~js" --protocol-select "ping|echo"

# Run only TCP combinations
./run.sh --transport-select "tcp"

# Run all but ignore slow identify tests
./run.sh --protocol-ignore "identify"

# Run with 4 parallel workers
./run.sh --workers 4 -y

# Enable debug logging inside containers
./run.sh --debug -y

# List tests that would be selected without running them
./run.sh --list-tests

# List tests including the ones that would be ignored
./run.sh --list-tests --show-ignored

# Force regeneration of the test matrix (bypass cache)
./run.sh --force-matrix-rebuild -y
```

### Filtering Examples

```bash
# Only rust vs js ping tests over tcp
./run.sh --impl-select "~rust|~js" --transport-select "tcp" --protocol-select "ping"

# All echo tests, all implementations, yamux only
./run.sh --protocol-select "echo" --muxer-select "yamux"

# Everything except python
./run.sh --impl-ignore "~python"
```

## How It Works

### Test Matrix

For every pair `(dialer, listener)` the matrix generator (`lib/generate-tests.sh`)
computes:

```
{dialer} × {listener} × {common transports} × {common secureChannels} × {common muxers} × {common protocols}
```

Only protocol combinations supported by **both** implementations (the
intersection of their `protocols:` lists in `images.yaml`) are emitted.

Each test row looks like:

```
js-v3.x x go-v0.45 (tcp, noise, yamux) [ping]
js-v3.x x js-v3.x  (tcp, noise, yamux) [echo]
js-v3.x x js-v3.x  (ws,  noise, yamux) [identify]
```

### Test Execution

Each test runs as a two-container `docker-compose` job:

1. **listener** starts, registers the target protocol handler, and publishes
   its multiaddr to a Redis key (`{TEST_KEY}_listener_multiaddr`).
2. **dialer** reads the multiaddr from Redis (blocking pop), dials, exercises
   the protocol, and exits with code `0` (pass) or `1` (fail).
3. `run-single-test.sh` waits for the dialer to exit
   (`--exit-code-from dialer`) and records the result.

The `PROTOCOL` environment variable is passed to both containers so the test
app knows which protocol exercise to run.

### Protocol Behaviour

| Protocol | Listener | Dialer |
|----------|----------|--------|
| ping | Starts, publishes multiaddr, waits | Dials, sends ping, logs latency YAML |
| echo | Registers `/echo/1.0.0` handler (pipe stream back), publishes, waits | Dials, opens stream, sends payload, reads back, verifies integrity |
| identify | Starts (identify runs automatically on connect), publishes, waits | Dials, calls `identify(conn)`, verifies non-empty protocol list |

### Output

Each test run produces:

```
<cache-dir>/test-run/<test-pass>/
  results.yaml              # summary + per-test records
  results.md                # matrix view grouped by protocol
  LATEST_TEST_RESULTS.md    # flat detailed results table
  logs/                     # per-test container logs
  results/                  # per-test individual YAML files
  docker-compose/           # generated compose files (for debugging)
  inputs.yaml               # snapshot of flags used (for re-running)
  test-matrix.yaml          # generated test matrix (cached)
```

## File Structure

```
misc/
  run.sh                  ← main entry point
  images.yaml             ← implementation definitions + protocol support lists
  README.md               ← this file
  lib/
    generate-tests.sh     ← test matrix generation (adds protocol dimension)
    run-single-test.sh    ← single test execution (passes PROTOCOL to containers)
    generate-dashboard.sh ← generates results.md + LATEST_TEST_RESULTS.md
  images/
    js/
      v3.x/               ← js-libp2p v3 Node.js test app
        Dockerfile
        package.json
        .aegir.js
        tsconfig.json
        src/index.ts
        test/
          dialer.spec.ts   ← dispatches to ping / echo / identify dialer test
          listener.spec.ts ← dispatches to ping / echo / identify listener test
          fixtures/
            get-libp2p.ts  ← creates configured libp2p node
            redis-proxy.ts ← sends Redis commands via the HTTP proxy
```

## Adding a New Protocol

1. Add the protocol name to the `protocols:` list of each implementation in
   `images.yaml` that supports it.
2. Add the corresponding dialer and listener logic to the relevant test app
   (e.g. `test/dialer.spec.ts` and `test/listener.spec.ts` for JS).
3. Update this README.

## Relationship to Other Test Suites

| Suite | Focus |
|-------|-------|
| [transport](../transport) | Dial + ping connectivity matrix across all transports |
| **misc** (this) | Protocol semantics validation (ping, echo, identify, …) |
| [perf](../perf) | Throughput and latency benchmarks |
| [hole-punch](../hole-punch) | NAT traversal correctness |
