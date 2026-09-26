# libp2p AutoNAT Protocol Interoperability Tests

Bash-driven interoperability tests for libp2p AutoNAT implementations (`/libp2p/autonat/1.0.0`). The suite mirrors the overall design of [`transport/`](../transport/README.md) and [`kad-dht/`](../kad-dht/README.md): Docker Compose per test, a shared Redis instance for coordination, and a generated test matrix from `images.yaml`.

## Overview

Each test runs **two containers** in distinct roles:

| Role | Purpose |
|------|---------|
| **server** | Runs the AutoNAT dial-back service; publishes its multiaddr to Redis and dials clients back on request |
| **client** | Connects to the server, asks to be dialed back on its listen addrs, and reports the verdict |

The goal is to verify that implementations agree on reachability across language stacks: a directly-dialable client must get an `OK` verdict.

**Current implementations** (see [`images.yaml`](images.yaml)):

- **go** — go-libp2p (`autonat-go`, v0.49.0)
- **py** — py-libp2p (`autonat-py`, working tree; AutoNAT spec fixes unreleased)

## Test Naming

Test IDs follow:

```
{server}_x_{client}
```

**Example:** `go_x_py` — can a Python client prove its reachability to a Go AutoNAT server?

## Test Matrix Size

`lib/generate-tests.sh` builds the **full permutation** of server × client:

```
number of tests = N²
```

| Implementations | Tests |
|-----------------|-------|
| 2 (`go`, `py`) | 4 |

## Quick Start

```bash
cd autonat
./run.sh
./run.sh --test-select "go_x_py"   # single test
./run.sh --list-tests              # inspect matrix
./run.sh --force-image-rebuild     # rebuild images
```

## Coordination & Flow

Synchronization via Redis (`transport-redis:6379`):

```
Server starts -> publishes multiaddr to `<testKey>_server_addr`
                                              |
Client reads `<testKey>_server_addr` <--------+
    |
    +-> connects to Server -> sends DIAL with its listen addrs
    +-> Server dials back -> responds DIAL_RESPONSE{OK} (or error)
    +-> client prints `verdict:` + `status: pass/fail` -> exits
```

## Directory Structure

```
autonat/
├── README.md                # This file
├── images.yaml              # Implementation definitions and image names
├── run.sh                   # Entrypoint test runner
├── images/
│   ├── go/                  # Go harness (main.go + go.mod/go.sum + Dockerfile)
│   └── py/                  # Python harness (node.py + Dockerfile, deps via pip)
└── lib/
    ├── build-images.sh      # Image build helpers
    ├── generate-tests.sh    # Matrix generation (N² permutations)
    └── run-single-test.sh   # Single test runner (Docker compose + Redis)
```
