# Self-Hosted GitHub Actions Runner for libp2p/unified-testing

Containerized, ephemeral GitHub Actions runner for the
[libp2p/unified-testing](https://github.com/libp2p/unified-testing) repository.

The runner uses the **Docker-outside-of-Docker (DooD)** pattern: it mounts the
host's Docker socket so that workflow jobs can build images, run
`docker compose` test stacks, and manage containers directly on the host daemon.
After each job the runner automatically deregisters and the container restarts to
pick up the next job with a clean slate.

## Files

| File                 | Purpose                                                       |
|----------------------|---------------------------------------------------------------|
| `Dockerfile`         | Builds the runner image (Debian 13 slim + GitHub Actions runner + Docker CLI + project tooling) |
| `docker-compose.yaml`| Runs the runner container with the correct mounts and environment |
| `entrypoint.sh`      | Obtains a registration token, configures the runner, and starts it in ephemeral mode |
| `env`                | Template for the `.env` file (copy and fill in before starting) |

## Prerequisites

- **Linux host** (x86_64) with Docker Engine 20.10+ and the Docker Compose v2
  plugin (`docker compose`).
- **Admin access** to the `libp2p/unified-testing` repository (needed to create
  a Personal Access Token with the right scopes).
- A `/srv/cache` directory on the host (the test framework uses it for build
  caching, test matrices, and results). Create it if it does not exist:
  ```bash
  sudo mkdir -p /srv/cache
  sudo chown "$(id -u):$(id -g)" /srv/cache
  ```

## Setup

### 1. Create a GitHub Personal Access Token

The runner needs a PAT to request short-lived registration tokens from the
GitHub API. You can use either a **classic** or a **fine-grained** token.

#### Option A: Classic PAT

1. Go to <https://github.com/settings/tokens>.
2. Click **Generate new token (classic)**.
3. Give it a descriptive name (e.g. `libp2p-runner`).
4. Select the **`repo`** scope (full control of private repositories).
5. Click **Generate token** and copy the value into `.env`.

#### Option B: Fine-Grained PAT (recommended)

1. Go to <https://github.com/settings/tokens?type=beta>.
2. Click **Generate new token**.
3. Set **Resource owner** to the org or user that owns the fork (e.g. `libp2p`).
4. Under **Repository access**, select **Only select repositories** and choose
   `libp2p/unified-testing`.
5. Under **Repository permissions**, set **Administration** to
   **Read and write**.
6. Click **Generate token** and copy the value into `.env`.

### 2. Configure Environment Variables

Copy the template `env` file `.env`:

```bash
cp env .env
```

Edit `.env` and fill in the values:

```
RUNNER_NAME=my-runner
ACCESS_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

- **`RUNNER_NAME`** -- A human-readable name for this runner (it appears in the
  GitHub UI). The compose file appends `-unified-testing` automatically.
- **`ACCESS_TOKEN`** -- A GitHub Personal Access Token created in step 1.

The `.env` file is read automatically by Docker Compose and is used to
interpolate `${RUNNER_NAME}` and `${ACCESS_TOKEN}` in `docker-compose.yaml`.
Keep this file private -- do not commit it to version control.

### 3. Update docker-compose.yaml

Before first use, edit `docker-compose.yaml` and replace the placeholder image
reference with your actual GHCR username or organization:

```yaml
image: ghcr.io/<username>/libp2p-gh-runner:latest
```

If you need to point the runner at a different repository, update the
`REPO_URL` environment variable in the service definition as well.

### 4. Build the Docker image

Build the runner image form the Dockerfile:

```bash
docker build -t ghcr.io/<username>/libp2p-gh-runner:latest .
```

Replace `<username>` with your GitHub username or organization.

### 5. Push the Image to GHCR

Authenticate with the GitHub Container Registry, then push:

```bash
# Log in (use your GitHub username and a PAT with write:packages scope)
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <username> --password-stdin

# Push the image
docker push ghcr.io/<username>/libp2p-gh-runner:latest
```

The PAT used for GHCR authentication needs the `write:packages` scope (classic
token) or the **Packages -- Read and write** permission (fine-grained token).
This can be the same token as `ACCESS_TOKEN` if you add the required scope, or
a separate token.

### 6. Start the Runner

With the `.env` file in place and the image available, start the runner:

```bash
docker compose up -d
```

Docker Compose will:

1. Pull the image from `ghcr.io` (if not already local).
2. Start the container with the environment variables from `.env`.
3. The entrypoint script exchanges `ACCESS_TOKEN` for a short-lived
   registration token via the GitHub API.
4. The runner registers itself with the repository in ephemeral mode.
5. It picks up a single job, executes it, then exits.
6. Because `restart: unless-stopped` is set, Docker automatically restarts the
   container, which registers a fresh ephemeral runner for the next job.

### 7. Verify registration

Open **Settings > Actions > Runners** in the repository:

<https://github.com/libp2p/unified-testing/settings/actions/runners>

Or use the GitHub CLI:

```bash
gh api repos/libp2p/unified-testing/actions/runners --jq '.runners[] | "\(.name) \(.status)"'
```

The runner should show as **Idle** (waiting for work) or **Active** (running a
job).

## Useful Commands

```bash
# View logs
docker compose logs -f

# Stop the runner
docker compose down

# Rebuild and restart after Dockerfile changes
docker compose up -d --build

# Pull a newer image and restart
docker compose pull && docker compose up -d
```

## How It Works

The `entrypoint.sh` script runs each time the container starts:

1. **Validates** that `REPO_URL` (or `ORG_NAME` + `RUNNER_SCOPE=org`) and
   `ACCESS_TOKEN` are set.
2. **Requests a registration token** from the GitHub API using the PAT.
3. **Configures the runner** with `--ephemeral`, `--unattended`, and
   `--replace` flags so it handles exactly one job and then exits cleanly.
4. **Starts the runner** with `exec ./run.sh`, which takes over the container
   process.

Because the runner is ephemeral, each job gets a completely clean environment
with no leftover state from previous runs.

```
Host Docker daemon
 |
 +-- runner container (this image)
 |     - mounts /var/run/docker.sock
 |     - entrypoint.sh registers with GitHub, runs ONE job, exits
 |     - restart: unless-stopped -> comes back up for next job
 |
 +-- test containers (siblings, NOT children)
 |     - started by the runner via `docker compose` on the host daemon
 |     - use their own networks (perf-network, transport-network, etc.)
 |
 +-- redis container
       - started by lib/lib-global-services.sh during test runs
```

The runner container and the test containers are **sibling containers** on the
host daemon. The runner talks to Docker through the mounted socket; it does not
need a special network to reach the test containers.

## Security Considerations

| Aspect | Details |
|--------|---------|
| **Docker socket mount** | Grants the container full control of the host Docker daemon. This is inherent to the DooD pattern and required by the test framework. Mitigate by running on a dedicated host. |
| **Root execution** | The runner runs as root inside the container (`RUNNER_ALLOW_RUNASROOT=1`). This is required for Docker socket access. The container is ephemeral and disposable. |
| **SELinux (`label:disable`)** | Required on SELinux-enabled hosts so the container can manage sibling containers through the socket. |
| **Ephemeral isolation** | Each job gets a fresh runner registration. After the job completes the runner deregisters and the container restarts cleanly. No state leaks between jobs. |
| **Token security** | The PAT is only used to obtain short-lived registration tokens. Keep `.env` out of version control (it is git-ignored). Rotate the PAT periodically. |

## Maintenance

### Updating the runner version

The GitHub Actions runner version is pinned in the Dockerfile:

```dockerfile
ARG RUNNER_VERSION=2.330.0
```

To update, change the version number and rebuild:

```bash
docker build -t ghcr.io/<username>/libp2p-gh-runner:latest .
docker compose up -d   # recreates the container with the new image
```

### Viewing logs

```bash
docker compose logs -f
```

### Stopping the runner

```bash
docker compose down
```

The runner will deregister from GitHub automatically when it finishes its current
job (or immediately if idle, on the next restart cycle).

## Troubleshooting

### Registration token request fails

```
ERROR: Failed to get registration token from GitHub.
```

- Verify `ACCESS_TOKEN` in `.env` is valid and not expired.
- Ensure the token has the correct scope (see step 2 above).
- Check network connectivity: `curl -s https://api.github.com/zen`

### Runner shows as Offline in GitHub UI

- Check container status: `docker compose ps`
- Check logs: `docker compose logs --tail 50`
- The runner may have just finished a job and be in the restart cycle. Wait a
  few seconds and refresh.

### Docker commands fail inside workflow jobs

```
Cannot connect to the Docker daemon at unix:///var/run/docker.sock
```

- Verify the socket is mounted: `docker compose exec runner-unified-testing ls -la /var/run/docker.sock`
- Verify the host Docker daemon is running: `systemctl status docker`
- On SELinux hosts, ensure `label:disable` is set in `docker-compose.yaml`.

### `/srv/cache` permission errors

- Ensure the directory exists and is writable:
  ```bash
  ls -la /srv/cache
  ```
- The container runs as root, so host-side permissions are rarely the issue.
  Check that the directory is not on a read-only filesystem.
