FROM golang:1.24.6-alpine AS builder

WORKDIR /workspace

COPY main.go go.mod go.sum* ./
COPY perf.go ./

# Download dependencies
RUN go mod download

# Build the perf binary
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o perf .

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /workspace/perf .

ENTRYPOINT ["/app/perf"]
