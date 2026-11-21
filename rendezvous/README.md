# libp2p Rendezvous Protocol Interoperability Tests

Bash-driven interoperability tests for libp2p Rendezvous Protocol implementations (`/rendezvous/1.0.0`). The suite mirrors the overall design of [`transport/`](../transport/README.md) and [`kad-dht/`](../kad-dht/README.md): Docker Compose per test, a shared Redis instance for coordination, and a generated test matrix from `images.yaml`.

## Overview

Each test runs **three containers** in distinct roles:

| Role | Purpose |
|------|---------|
| **server** | Runs the Rendezvous Point service (`/rendezvous/1.0.0`); publishes its multiaddr to Redis and serves registration and discovery requests |
| **registrant** | Connects to the Rendezvous server, registers itself under a test-specific namespace with TTL, and listens for incoming ping requests |
| **discoverer** | Connects to the Rendezvous server, queries the namespace to discover the registrant, connects directly to the discovered registrant peer, and exchanges a ping/pong stream |

The goal is to verify that implementations can interoperate across the full server → register → discover → direct dial path, across different language stacks.

**Current implementations** (see [`images.yaml`](images.yaml)):

- **go** — berty/go-libp2p-rendezvous (`rendezvous-go`, v0.5.1)
- **py** — py-libp2p (`rendezvous-py`, libp2p==0.7.0)

## Test Naming

Test IDs follow:

```
{server}_x_{registrant}_x_{discoverer}
```

The `_x_` separator is literal text. Each segment is an implementation id from `images.yaml`.

**Example:** `go_x_py_x_go`

| Segment | Role | Implementation |
|---------|------|----------------|
| 1st | server | `go` |
| 2nd | registrant | `py` |
| 3rd | discoverer | `go` |

This test verifies: *Can a Go node discover a Python registrant through a Go rendezvous server, and successfully dial that Python node?*

## Test Matrix Size

`lib/generate-tests.sh` builds the **full permutation** of server × registrant × discoverer for every implementation in `images.yaml`:

```
number of tests = N³
```

where `N` is the number of implementations.

| Implementations | Tests |
|-----------------|-------|
| 2 (`go`, `py`) | 8 |
| 3 (e.g. + `rust`) | 27 |
| 4 (e.g. + `js`) | 64 |

### All 8 Permutations Tested:

1. `go_x_go_x_go`
2. `go_x_go_x_py`
3. `go_x_py_x_go`
4. `go_x_py_x_py`
5. `py_x_go_x_go`
6. `py_x_go_x_py`
7. `py_x_py_x_go`
8. `py_x_py_x_py`

## Quick Start

### Run the full suite

```bash
cd rendezvous
./run.sh
```

### Run a subset of tests

```bash
# Run single test
./run.sh --test-select "go_x_py_x_go"

# Run all tests with Python as discoverer
./run.sh --test-select "*_x_*_x_py"

# Skip homogeneous tests
./run.sh --test-ignore "go_x_go_x_go|py_x_py_x_py"
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

Synchronization across the three nodes is handled via Redis (`transport-redis:6379`):

```
Server starts -> publishes multiaddr to `<testKey>_server_addr`
                                                |
Registrant reads `<testKey>_server_addr` <------+
      |
      +-> connects to Server -> registers namespace with TTL (300s)
      +-> publishes `<testKey>_registrant_id` & `<testKey>_registrant_done`
                                                |
Discoverer reads Server addr & Registrant done <-+
      |
      +-> connects to Server -> discovers Registrant peer
      +-> dials Registrant directly on `/ping/1.0.0`
      +-> exchanges ping ("ping" -> "pong") -> exits 0 (pass)
```

## Directory Structure

```
rendezvous/
├── README.md                # Usage guide and architectural documentation
├── images.yaml              # Implementation definitions and image names
├── run.sh                   # Entrypoint test runner
├── images/
│   ├── go/                  # Go harness (main.go + go.mod/go.sum + Dockerfile).
│   │                        # Uses the maintained berty/go-libp2p-rendezvous
│   │                        # fork (v0.5.1) from the Go module proxy: the
│   │                        # official libp2p/go-libp2p-rendezvous repo is
│   │                        # archived and not installable as a module.
│   └── py/                  # Python implementation (py-libp2p, deps via pip)
│       ├── Dockerfile
│       └── node.py          # Test node harness (server, registrant, discoverer)
└── lib/
    ├── build-images.sh      # Image build helpers
    ├── generate-tests.sh    # Matrix generation (N³ permutations)
    └── run-single-test.sh   # Single test runner (Docker compose + Redis)
```

## Test Results

All 8 permutations passed successfully:

| Test ID | Server | Registrant | Discoverer | Status | Direct Dial Ping/Pong |
|---|---|---|---|---|---|
| `go_x_go_x_go` | `go` | `go` | `go` | **pass** | OK (< 1s) |
| `go_x_go_x_py` | `go` | `go` | `py` | **pass** | OK (~2s) |
| `go_x_py_x_go` | `go` | `py` | `go` | **pass** | OK (~1s) |
| `go_x_py_x_py` | `go` | `py` | `py` | **pass** | OK (~2s) |
| `py_x_go_x_go` | `py` | `go` | `go` | **pass** | OK (~2s) |
| `py_x_go_x_py` | `py` | `go` | `py` | **pass** | OK (~2s) |
| `py_x_py_x_go` | `py` | `py` | `go` | **pass** | OK (~2s) |
| `py_x_py_x_py` | `py` | `py` | `py` | **pass** | OK (~2s) |
