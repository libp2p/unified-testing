FROM lukemathwalker/cargo-chef:latest-rust-slim-trixie AS chef
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake build-essential libclang-dev \
    && rm -rf /var/lib/apt/lists/*

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# Build dependencies - this is the caching Docker layer!
RUN cargo chef cook --release --recipe-path recipe.json
# Build application
COPY . .
RUN RUSTFLAGS='-C target-feature=+crt-static' cargo build --release --target $(rustc -vV | grep host | awk '{print $2}')
RUN cp /app/target/$(rustc -vV | grep host | awk '{print $2}')/release/perf-tquic /usr/local/bin/perf-tquic

FROM debian:trixie-slim
COPY --from=builder /usr/local/bin/perf-tquic /usr/local/bin/perf-tquic
ENV RUST_BACKTRACE=1
ENTRYPOINT ["/usr/local/bin/perf-tquic"]
