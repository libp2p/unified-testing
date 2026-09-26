FROM golang:1.26-bookworm AS builder

WORKDIR /src

# Copy go.mod/go.sum first so dependency download is cached separately from source
COPY go.mod go.sum ./

# Download all dependencies from the Go module proxy
RUN --mount=type=cache,target=/root/go/pkg/mod \
    go mod download

# Copy the main program source
COPY main.go .

# Build — CGO required for go-sqlite3 (used by the rendezvous server role)
RUN --mount=type=cache,target=/root/go/pkg/mod \
    CGO_ENABLED=1 go build -o /app/node .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /app/node /app/node
ENTRYPOINT ["/app/node"]
