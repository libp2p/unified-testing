# libp2p Bootstrap Process Interoperability Tests

Bash-driven interoperability tests for the libp2p **bootstrap process** (well-known
peer → peerstore → dial → verify). The suite mirrors the overall design of the
`mdns/` suite: Docker Compose per test, a shared Redis instance for
coordination, and a generated test matrix from `images.yaml`.

## Scope note

libp2p has **no bootstrap wire protocol** on any stack — bootstrap is the
*process* of learning a well-known peer address, storing it permanently, and
(re)dialing it. What this suite verifies is that each implementation's
bootstrap machinery works against a live peer of the other implementation:
py-libp2p runs its real `BootstrapDiscovery` (`new_host(bootstrap=[...])`
→ validate → peerstore → dial → reconnect loop) and never dials manually;
the Go joiner mirrors the same steps explicitly (parse → permanent peerstore
→ connect with retry), since go-libp2p ships no bootstrap module. The pass
criterion is a connection established *by the bootstrap path*, verified usable
via ping/pong on `/ping/1.0.0`.

## Overview

Each test runs **two containers** on the same Docker network
(`bootstrap-network`):

| Role | Purpose |
|------|---------|
| **bootstrap** | Well-known node; listens, publishes its multiaddr to Redis, serves ping |
| **joiner** | Starts configured with the bootstrap multiaddr; must end up connected to it via its bootstrap machinery, then ping/pong |

**Current implementations** (see [`images.yaml`](images.yaml)):

- **go** — go-libp2p v0.49.0 (`bootstrap-go`)
- **py** — py-libp2p (`bootstrap-py`, `libp2p==0.8.0`)

## Test Naming

Test IDs follow:

```
{joiner}_x_{bootstrap}
```

**Example:** `py_x_go` — *can a Python joiner bootstrap from a Go node?*

## Test Matrix Size

`lib/generate-tests.sh` builds the full joiner × bootstrap permutation:

```
number of tests = N²
```

| Implementations | Tests |
|-----------------|-------|
| 2 (`go`, `py`) | 4 |

### All 4 Permutations Tested:

1. `go_x_go`
2. `go_x_py`
3. `py_x_go`
4. `py_x_py`

## Quick Start

```bash
cd bootstrap
./run.sh                        # full suite
./run.sh --test-select "py_x_go" # single test
./run.sh --list-tests            # inspect matrix
./run.sh --force-image-rebuild   # rebuild images
```

## Coordination & Flow

```
Bootstrap node starts -> publishes `<testKey>_bootstrap_addr` to Redis
                                                |
Joiner reads `<testKey>_bootstrap_addr` <-------+
       |
       +-> feeds it to its bootstrap machinery (no manual dial)
       +-> waits until the bootstrap peer appears in its connections
       +-> opens `/ping/1.0.0`, exchanges ping/pong -> exits 0 (pass)
```

## Directory Structure

```
bootstrap/
├── README.md                # this file
├── images.yaml              # implementation registry
├── run.sh                   # entrypoint test runner
├── images/
│   ├── go/                  # Go harness (bootstrap-process mirror)
│   └── py/                  # Python harness (real BootstrapDiscovery)
│       ├── Dockerfile
│       └── node.py
└── lib/
    ├── build-images.sh
    ├── generate-tests.sh    # N² permutations
    └── run-single-test.sh
```
