# libp2p mDNS Protocol Interoperability Tests

Bash-driven interoperability tests for libp2p mDNS peer discovery (`_p2p._udp.local`, multicast `224.0.0.251:5353`). The suite mirrors the overall design of [`rendezvous/`](../rendezvous/README.md) (when available) and [`kad-dht/`](../kad-dht/README.md): Docker Compose per test, a shared Redis instance for coordination, and a generated test matrix from `images.yaml`.

## Overview

Each test runs **two containers** on the same Docker network (`mdns-network`, required for multicast):

| Role | Purpose |
|------|---------|
| **advertiser** | Starts a libp2p host with mDNS enabled; broadcasts itself via mDNS, publishes its peer ID to Redis, and serves ping requests |
| **discoverer** | Starts a libp2p host with mDNS enabled; waits for the expected advertiser peer ID (via Redis), waits for the mDNS discovery event, dials the discovered peer directly, and exchanges a ping/pong stream |

The goal is to verify that implementations discover each other over mDNS across language stacks, without any bootstrap or central server.

**Current implementations** (see [`images.yaml`](images.yaml)):

- **go** — go-libp2p v0.49.0 (`mdns-go`, `p2p/discovery/mdns.NewMdnsService`)
- **py** — py-libp2p (`mdns-py`, `libp2p==0.8.0`, `new_host(enable_mDNS=True)`)

## Test Naming

Test IDs follow:

```
{advertiser}_x_{discoverer}
```

The `_x_` separator is literal text. Each segment is an implementation id from `images.yaml`.

**Example:** `go_x_py`

| Segment | Role | Implementation |
|---------|------|----------------|
| 1st | advertiser | `go` |
| 2nd | discoverer | `py` |

This test verifies: *Can a Python node discover a Go advertiser via mDNS, and successfully dial it?*

## Test Matrix Size

`lib/generate-tests.sh` builds the **full permutation** of advertiser × discoverer for every implementation in `images.yaml`:

```
number of tests = N²
```

where `N` is the number of implementations.

| Implementations | Tests |
|-----------------|-------|
| 2 (`go`, `py`) | 4 |
| 3 (e.g. + `rust`) | 9 |
| 4 (e.g. + `js`) | 16 |

### All 4 Permutations Tested:

1. `go_x_go`
2. `go_x_py`
3. `py_x_go`
4. `py_x_py`

## Quick Start

### Run the full suite

```bash
cd mdns
./run.sh
```

### Run a subset of tests

```bash
# Run single test
./run.sh --test-select "go_x_py"

# Run all tests with Python as discoverer
./run.sh --test-select "*_x_py"
```

### Inspect the matrix without running

```bash
./run.sh --list-tests
```

### Build images only

```bash
./run.sh --force-image-rebuild
```

## Coordination & Flow

Synchronization across the two nodes uses Redis (`mdns-redis:6379`); peer discovery itself uses mDNS multicast (no Redis):

```
Advertiser starts mDNS -> publishes `<testKey>_advertiser_id`
                                                |
Discoverer reads `<testKey>_advertiser_id` <---+
       |
       +-> starts mDNS -> waits for discovery event matching advertiser_id
       +-> dials discovered advertiser directly on `/ping/1.0.0`
       +-> exchanges ping ("ping" -> "pong") -> exits 0 (pass)
```

## Directory Structure

```
mdns/
├── README.md                # Usage guide and architectural documentation
├── images.yaml              # Implementation definitions and image names
├── run.sh                   # Entrypoint test runner
├── images/
│   ├── go/                  # Go harness (main.go + go.mod/go.sum + Dockerfile)
│   └── py/                  # Python harness (py-libp2p, deps via pip)
│       ├── Dockerfile
│       └── node.py          # Test node harness (advertiser, discoverer)
└── lib/
    ├── build-images.sh      # Image build helpers
    ├── generate-tests.sh    # Matrix generation (N² permutations)
    └── run-single-test.sh   # Single test runner (Docker compose + Redis)
```

## Notes

- mDNS requires multicast on the shared `mdns-network` Docker bridge network (`224.0.0.251:5353`). Both containers must be on the same network.
- Redis is only used to exchange the expected advertiser peer ID and readiness; discovery assertions always come from real mDNS events.
