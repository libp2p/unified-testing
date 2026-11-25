# minip2p (Rust) for the relay suite. The app lives in the minip2p repo
# (tests/interop/unified-testing, binary minip2p-relay-interop); lib/build-images.sh
# vendors deepso7/minip2p at the commit pinned in images.yaml into ./minip2p.
FROM rust:1.91-slim-bookworm AS builder
WORKDIR /src
# The root manifest supplies the `workspace = true` fields the crates inherit.
COPY minip2p/Cargo.toml ./
COPY minip2p/crates crates
COPY minip2p/transports transports
COPY minip2p/tests/interop/unified-testing tests/interop/unified-testing
RUN cargo build --release --locked \
      --manifest-path tests/interop/unified-testing/Cargo.toml \
      --bin minip2p-relay-interop

FROM debian:bookworm-slim
COPY --from=builder /src/tests/interop/unified-testing/target/release/minip2p-relay-interop /app/node
ENTRYPOINT ["/app/node"]
