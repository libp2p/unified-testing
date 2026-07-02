# Kademlia DHT Interoperability Tests

Bash-driven interoperability tests for libp2p Kademlia DHT implementations. The suite mirrors the overall design of [`transport/`](../transport/README.md): Docker Compose per test, a shared Redis for coordination, and a generated test matrix from `images.yaml`.

## Overview

Each test runs **three containers** in distinct roles:

| Role | Purpose |
|------|---------|
| **bootstrap** | Seeds the DHT; publishes its multiaddr to Redis and stays up for the test |
| **provider** | Connects to the bootstrap, announces a provider record, and stores a DHT value |
| **querier** | Connects to the bootstrap, looks up the provider record, and reads the stored value |

The goal is to verify that implementations can interoperate across the full bootstrap → provide → query path, not only within a single language.

**Current implementations** (see [`images.yaml`](images.yaml)):

- **py** — py-libp2p (`kad-dht-py`)
- **dotnet** — NethermindEth/dotnet-libp2p (`kad-dht-dotnet`)

## Test naming

Test IDs follow:

```
{bootstrap}_x_{provider}_x_{querier}
```

The `_x_` separator is literal text (not multiplication). Each segment is an implementation id from `images.yaml`.

**Example:** `py_x_py_x_dotnet`

| Segment | Role | Implementation |
|---------|------|----------------|
| 1st | bootstrap | `py` |
| 2nd | provider | `py` |
| 3rd | querier | `dotnet` |

So this test asks: *can a .NET querier find a record published by a Python provider on a Python-bootstrapped DHT?*

## Test matrix size

`lib/generate-tests.sh` builds the **full permutation** of bootstrap × provider × querier for every implementation in `images.yaml`:

```
number of tests = N³
```

where `N` is the number of implementations.

| Implementations | Tests |
|-----------------|-------|
| 2 (`py`, `dotnet`) | 8 |
| 3 (e.g. + `go`) | 27 |
| 4 (e.g. + `rust`) | 64 |
| 5 (e.g. + `js`) | 125 |

Adding a new implementation does not change the naming scheme — only the ids used in each position. Every ordered triple is a distinct interoperability scenario because failures can be role-specific (e.g. .NET as bootstrap with Python as provider may behave differently from the reverse).

For large `N`, run the full matrix in nightly or manual CI jobs and use filtering on pull requests (see below).

## What each test does

1. **Generate matrix** — `lib/generate-tests.sh` writes `test-matrix.yaml`
2. **Build images** — Docker images for implementations required by the selected tests
3. **Start Redis** — global `transport-redis` on `transport-network`
4. **Per test** — `lib/run-single-test.sh` creates an isolated Compose stack:
   - `ROLE=bootstrap|provider|querier`
   - `TEST_KEY` — short hash of the test name; namespaces Redis keys per test
5. **Bootstrap** — starts libp2p, writes `{TEST_KEY}_bootstrap_addr` to Redis
6. **Provider** — waits for bootstrap addr, connects, runs DHT provide/put, sets `{TEST_KEY}_provider_done`
7. **Querier** — waits for bootstrap addr and provider done, connects, runs DHT find/get, prints result to stdout
8. **Pass/fail** — harness treats a test as failed if the querier exits non-zero **or** prints `status: fail` in its logs

### DHT operations exercised

Both implementations currently run:

- **Test 1** — provider announces key `interop-test-key` (`Provide` / `find_providers`)
- **Test 3/4** — provider stores and querier reads `/example/data` (`put_value` / `get_value`)

## How to run

### Prerequisites

```bash
./run.sh --check-deps
```

Required: bash 4.0+, docker 20.10+, docker compose, yq 4.0+, git.

### Basic usage

```bash
# Full matrix (8 tests with py + dotnet)
./run.sh

# Help and discovery
./run.sh --help
./run.sh --list-images
./run.sh --list-tests

# Single test
./run.sh --test-select "py_x_py_x_dotnet"

# Rebuild images (e.g. after changing node source)
./run.sh --force-image-rebuild
```

Docker images are cached between runs. Vendored sources (e.g. `dotnet-libp2p`) are cloned into `kad-dht/.cache/git-repos/` and copied into the build context only when the pinned commit changes. Use `--force-image-rebuild` to force a Docker rebuild.

### Filtering

| Option | Description |
|--------|-------------|
| `--test-select` | Run only tests whose id matches a pattern (pipe-separated) |
| `--test-ignore` | Skip tests matching a pattern |
| `--impl-select` | Limit which implementations are built |
| `--impl-ignore` | Exclude implementations from the build set |

Examples:

```bash
./run.sh --test-select "py_x_*"              # bootstrap is always py
./run.sh --test-ignore "*_x_dotnet_x_*"      # skip dotnet queriers
./run.sh --impl-select "py" --test-select "py_x_py_x_py"
```

## Results

Each run writes a timestamped directory:

```
kad-dht/results/<HHMMSS>-<DD>-<MM>-<YYYY>/
├── results.yaml          # summary + per-test status
├── test-matrix.yaml      # generated matrix
├── logs/<test-id>.log    # full Docker output per test
├── docker-compose/       # generated compose files
└── results/<test-id>.yaml
```

`run.sh` prints the results path when finished.

## CI

Pull requests that touch `kad-dht/**` run [`.github/workflows/kad-dht-interop-pr.yml`](../.github/workflows/kad-dht-interop-pr.yml) on self-hosted runners. The composite action [`.github/actions/run-bash-kad-dht-test`](../.github/actions/run-bash-kad-dht-test/action.yml) executes `./run.sh` and uploads the results directory as an artifact.

## Adding a new implementation

1. Add a node under `images/<id>/` implementing all three roles via `ROLE` env var
2. Add an entry to [`images.yaml`](images.yaml) with `id`, `imageName`, and `buildContext`
3. For vendored upstream repos, use the `source` block (see `dotnet` for `repo`, `commit`, `patchPath`, `patchFile`, `vendorDir`)
4. Re-run `./run.sh --list-tests` — the matrix grows to `N³` automatically

Each new node must:

- Publish bootstrap multiaddr to Redis key `{TEST_KEY}_bootstrap_addr`
- Set `{TEST_KEY}_provider_done` after successful provide/put
- Print `status: pass` or `status: fail` (and optional `error:` lines) on stdout for the querier role

## Directory layout

```
kad-dht/
├── README.md           # this file
├── run.sh              # entry point
├── images.yaml         # implementation definitions
├── images/
│   ├── py/             # py-libp2p node
│   └── dotnet/         # dotnet-libp2p node (+ interop-fix.patch)
├── lib/
│   ├── generate-tests.sh
│   ├── run-single-test.sh
│   └── build-images.sh
└── results/            # test output (gitignored)
```

## Relation to transport tests

| | **transport/** | **kad-dht/** |
|--|----------------|--------------|
| Roles | dialer × listener | bootstrap × provider × querier |
| Matrix axes | impl × transport × secure × muxer | impl³ (role permutations) |
| Coordination | Redis multiaddr handoff | Redis bootstrap addr + provider done |
| Success signal | dialer ping/pong | querier DHT lookup + `status: pass` |

Transport verifies connection establishment; kad-dht verifies DHT record propagation across implementations.
