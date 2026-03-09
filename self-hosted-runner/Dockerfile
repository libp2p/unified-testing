# ─────────────────────────────────────────────────────────────
# Minimal Debian 13 (trixie) + GitHub Actions runner + full BuildKit
# ─────────────────────────────────────────────────────────────
FROM debian:13-slim

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ALLOW_RUNASROOT=1

# Install only what is strictly required
# - GitHub runner dependencies (very small list)
# - Docker CLI + Buildx plugin (from official Docker repos)
# - BuildKit enabled by default for plain `docker build`
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg && \
    \
    # Add Docker's official GPG key and repository
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    \
    # Refresh with Docker repo and install everything
    apt-get update && \
    apt-get install -y --no-install-recommends \
        bc \
        ca-certificates \
        containerd.io \
        coreutils \
        docker-ce \
        docker-ce-cli \
        docker-buildx-plugin \
        docker-compose-plugin \
        gh \
        git \
        gnuplot \
        gzip \
        jq \
        libssl3 \
        liblttng-ust1 \
        libkrb5-3 \
        libicu76 \
        libunwind8 \
        libuuid1 \
        openssh-client \
        pandoc \
        patch \
        tar \
        wget \
        unzip \
        util-linux \
        zip && \
    rm -rf /var/lib/apt/lists/*

# Set up SSH
#RUN mkdir -p /root/.ssh && \
#    chmod 700 /root/.ssh

# Force BuildKit for ALL `docker build` commands (no DOCKER_BUILDKIT=1 needed)
RUN mkdir -p /root/.docker && \
    echo '{ "features": { "buildkit": "true" } }' > /root/.docker/config.json

# Install latest stable yq (mikefarah) — tiny binary, no deps
ENV YQ_VERSION=v4.49.2
RUN arch=$(dpkg --print-architecture) && \
    curl -L --fail -o /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}" && \
    chmod +x /usr/local/bin/yq

# Install AWS CLI v2 (used by daily-full-interop.yml for S3 uploads)
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp/aws-install && \
    /tmp/aws-install/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli && \
    rm -rf /tmp/awscliv2.zip /tmp/aws-install

# Install GitHub Actions runner (latest stable at time of writing)
ARG RUNNER_VERSION=2.330.0
WORKDIR /actions-runner

RUN curl -L -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" && \
    tar xzf runner.tar.gz && \
    rm runner.tar.gz && \
    ./bin/installdependencies.sh && \
    # Clean up runner's own apt caches
    rm -rf /var/lib/apt/lists/*

# Copy your entrypoint script (ephemeral registration)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
