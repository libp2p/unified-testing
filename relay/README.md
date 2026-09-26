# libp2p Circuit Relay v2 Interoperability Tests

Bash-driven interoperability tests for libp2p Circuit Relay v2 (`/libp2p/circuit/relay/0.2.0`). The suite mirrors the design of [`rendezvous/`](../rendezvous/README.md) (see `libp2p/unified-testing` PR #148): Docker Compose per test, a shared Redis instance for coordination, and a generated test matrix from `images.yaml`.

All peers share one Docker network (no NAT) — this suite tests **relay protocol interop** (reserve → dial through circuit → echo), not hole punching (see `hole-punch/` for DCUtR).

## Overview

Each test runs **three containers** in distinct roles:

| Role | Purpose |
|------|---------|
| **relay** | Runs the circuit relay v2 hop service; publishes its multiaddr to Redis and accepts reservations |
| **listener** | Connects to the relay, makes a reservation, publishes its peer ID, and serves a fixed-length echo protocol (`/relay-echo/1.0.0`) |
| **dialer** | Connects to the relay, dials the listener through a `p2p-circuit` address (retrying while the reservation propagates), and verifies the echo |

The goal is to verify relay interop across language stacks on the full relay → reserve → circuit-dial → echo path.

**Current implementations** (see [`images.yaml`](images.yaml)):

- **go** — go-libp2p v0.34.1 (`relay-go`)
- **py** — py-libp2p from `libp2p/py-libp2p@main` (`relay-py`)

## Test Naming

Test IDs follow:

```
{relay}_x_{listener}_x_{dialer}
```

The `_x_` separator is literal text. Each segment is an implementation id from `images.yaml`.

**Example:** `go_x_py_x_go`

| Segment | Role | Implementation |
|---------|------|----------------|
| 1st | relay | `go` |
| 2nd | listener | `py` |
| 3rd | dialer | `go` |

This test verifies: *Can a Go node reach a Python listener through a Go relay?*

## Test Matrix Size

`lib/generate-tests.sh` builds the **full permutation** of relay × listener × dialer for every implementation in `images.yaml`:

```
number of tests = N³
```

where `N` is the number of implementations (currently 2 → 8 tests).

## Running

```bash
./run.sh                        # full matrix (8 tests)
./run.sh --test-select "go_x_py" # subset by test-id pattern
./run.sh --force-image-rebuild   # rebuild images
./run.sh --list-tests            # list test IDs without running
```

The dialer is the pass/fail driver: it prints `status: pass` on a verified echo (exit 0) or `error: ...` + `status: fail` (exit non-zero). Results land in `results/<timestamp>/`.
