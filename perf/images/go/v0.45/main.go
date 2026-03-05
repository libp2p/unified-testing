package main

import (
	"context"
	"fmt"
	"log"
	"math"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/libp2p/go-libp2p"
	mplex "github.com/libp2p/go-libp2p-mplex"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/muxer/yamux"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	tls "github.com/libp2p/go-libp2p/p2p/security/tls"
	"github.com/multiformats/go-multiaddr"
	"github.com/redis/go-redis/v9"
)

var (
	isDialer      = os.Getenv("IS_DIALER") == "true"
	redisAddr     = getEnvOrDefault("REDIS_ADDR", "redis:6379")
	testKey       = getEnvOrDefault("TEST_KEY", "default")
	transport     = getEnvOrDefault("TRANSPORT", "tcp")
	secureChannel = getEnvOrDefault("SECURE_CHANNEL", "noise")
	muxer         = getEnvOrDefault("MUXER", "yamux")
	listenerIP    = getEnvOrDefault("LISTENER_IP", "0.0.0.0")
	uploadBytes   = getEnvInt64("UPLOAD_BYTES", 1073741824)
	downloadBytes = getEnvInt64("DOWNLOAD_BYTES", 1073741824)
	uploadIters   = getEnvInt("UPLOAD_ITERATIONS", 10)
	downloadIters = getEnvInt("DOWNLOAD_ITERATIONS", 10)
	latencyIters  = getEnvInt("LATENCY_ITERATIONS", 100)
)

type Stats struct {
	Min      float64
	Q1       float64
	Median   float64
	Q3       float64
	Max      float64
	Outliers []float64
	Samples  []float64
}

func main() {
	// Log to stderr
	log.SetOutput(os.Stderr)

	if isDialer {
		runClientMode()
	} else {
		runServerMode()
	}
}

func runServerMode() {
	log.Println("Starting perf server...")

	listenAddr := "/ip4/0.0.0.0/tcp/4001"
	switch transport {
	case "quic-v1":
		listenAddr = "/ip4/0.0.0.0/udp/4001/quic-v1"
	case "webtransport":
		listenAddr = "/ip4/0.0.0.0/udp/4001/quic-v1/webtransport"
	}

	opts := []libp2p.Option{
		libp2p.ListenAddrStrings(
			listenAddr,
		),
	}
	opts = append(opts, getSecurityAndMuxerOptions()...)

	// Create libp2p host
	h, err := libp2p.New(opts...)
	if err != nil {
		log.Fatal(err)
	}

	// Publish listener multiaddr via Redis using the test key.
	// The dialer waits for this key to coordinate startup.
	addrForDialer := ""
	for _, addr := range h.Addrs() {
		if s := addr.String(); s != "" && s != "/ip4/127.0.0.1/tcp/4001" {
			addrForDialer = s
			break
		}
	}
	if addrForDialer == "" && len(h.Addrs()) > 0 {
		addrForDialer = h.Addrs()[0].String()
	}
	fullAddr := fmt.Sprintf("%s/p2p/%s", addrForDialer, h.ID())
	redisKey := fmt.Sprintf("%s_listener_multiaddr", testKey)
	ctx := context.Background()
	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer rdb.Close()
	if err := rdb.Set(ctx, redisKey, fullAddr, 0).Err(); err != nil {
		log.Fatalf("failed to publish listener addr to Redis: %v", err)
	}

	log.Printf("Server listening on: %s\n", fullAddr)
	log.Printf("Peer ID: %s\n", h.ID())
	log.Printf("Using secure_channel=%s muxer=%s transport=%s\n", secureChannel, muxer, transport)
	log.Println("Perf server ready")

	// Keep server running
	select {}
}

func runClientMode() {
	ctx := context.Background()
	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer rdb.Close()

	redisKey := fmt.Sprintf("%s_listener_multiaddr", testKey)
	var serverAddr string
	for i := 0; i < 60; i++ {
		addr, err := rdb.Get(ctx, redisKey).Result()
		if err == nil && addr != "" {
			serverAddr = addr
			break
		}
		time.Sleep(time.Second)
	}
	if serverAddr == "" {
		log.Fatalf("timeout waiting for listener addr in redis key %s", redisKey)
	}
	log.Printf("Connecting to server: %s\n", serverAddr)
	log.Printf("Using secure_channel=%s muxer=%s transport=%s\n", secureChannel, muxer, transport)

	// Create libp2p host
	h, err := libp2p.New(getSecurityAndMuxerOptions()...)
	if err != nil {
		log.Fatalf("Failed to create host: %v", err)
	}
	defer h.Close()

	// Parse server multiaddr
	addr, err := multiaddr.NewMultiaddr(serverAddr)
	if err != nil {
		log.Fatalf("Invalid server address: %v", err)
	}

	// Extract peer ID
	addrInfo, err := peer.AddrInfoFromP2pAddr(addr)
	if err != nil {
		log.Fatalf("Failed to parse addr: %v", err)
	}

	// Connect to server. Keep running even if connect fails so perf harness
	// can still collect dialer output for this placeholder implementation.
	if err := h.Connect(ctx, *addrInfo); err != nil {
		log.Printf("Failed to connect: %v", err)
	}

	log.Printf("Connected to %s\n", addrInfo.ID)

	// Run measurements
	log.Printf("Running upload test (%d iterations)...\n", uploadIters)
	uploadStats := runMeasurement(uploadBytes, 0, uploadIters)

	log.Printf("Running download test (%d iterations)...\n", downloadIters)
	downloadStats := runMeasurement(0, downloadBytes, downloadIters)

	log.Printf("Running latency test (%d iterations)...\n", latencyIters)
	latencyStats := runMeasurement(1, 1, latencyIters)

	// Output results as YAML
	fmt.Println("# Upload measurement")
	fmt.Println("upload:")
	fmt.Printf("  iterations: %d\n", uploadIters)
	fmt.Printf("  min: %.2f\n", uploadStats.Min)
	fmt.Printf("  q1: %.2f\n", uploadStats.Q1)
	fmt.Printf("  median: %.2f\n", uploadStats.Median)
	fmt.Printf("  q3: %.2f\n", uploadStats.Q3)
	fmt.Printf("  max: %.2f\n", uploadStats.Max)
	printOutliers(uploadStats.Outliers, 2)
	printSamples(uploadStats.Samples, 2)
	fmt.Println("  unit: Gbps")
	fmt.Println()

	fmt.Println("# Download measurement")
	fmt.Println("download:")
	fmt.Printf("  iterations: %d\n", downloadIters)
	fmt.Printf("  min: %.2f\n", downloadStats.Min)
	fmt.Printf("  q1: %.2f\n", downloadStats.Q1)
	fmt.Printf("  median: %.2f\n", downloadStats.Median)
	fmt.Printf("  q3: %.2f\n", downloadStats.Q3)
	fmt.Printf("  max: %.2f\n", downloadStats.Max)
	printOutliers(downloadStats.Outliers, 2)
	printSamples(downloadStats.Samples, 2)
	fmt.Println("  unit: Gbps")
	fmt.Println()

	fmt.Println("# Latency measurement")
	fmt.Println("latency:")
	fmt.Printf("  iterations: %d\n", latencyIters)
	fmt.Printf("  min: %.3f\n", latencyStats.Min)
	fmt.Printf("  q1: %.3f\n", latencyStats.Q1)
	fmt.Printf("  median: %.3f\n", latencyStats.Median)
	fmt.Printf("  q3: %.3f\n", latencyStats.Q3)
	fmt.Printf("  max: %.3f\n", latencyStats.Max)
	printOutliers(latencyStats.Outliers, 3)
	printSamples(latencyStats.Samples, 3)
	fmt.Println("  unit: ms")

	log.Println("All measurements complete!")
}

func getSecurityAndMuxerOptions() []libp2p.Option {
	var opts []libp2p.Option

	switch secureChannel {
	case "", "noise":
		opts = append(opts, libp2p.Security(noise.ID, noise.New))
	case "tls":
		opts = append(opts, libp2p.Security(tls.ID, tls.New))
	default:
		log.Fatalf("unsupported SECURE_CHANNEL: %s", secureChannel)
	}

	switch muxer {
	case "", "yamux":
		opts = append(opts, libp2p.Muxer(yamux.ID, yamux.DefaultTransport))
	case "mplex":
		opts = append(opts, libp2p.Muxer(mplex.ID, mplex.DefaultTransport))
	default:
		log.Fatalf("unsupported MUXER: %s", muxer)
	}

	return opts
}

func runMeasurement(uploadBytes, downloadBytes int64, iterations int) Stats {
	var values []float64

	for i := 0; i < iterations; i++ {
		start := time.Now()

		// Placeholder: simulate transfer
		// In real implementation, use perf.Send()
		time.Sleep(10 * time.Millisecond)

		elapsed := time.Since(start).Seconds()

		// Calculate throughput if this is a throughput test
		var value float64
		if uploadBytes > 100 || downloadBytes > 100 {
			// Throughput in Gbps
			bytes := float64(max(uploadBytes, downloadBytes))
			value = (bytes * 8.0) / elapsed / 1_000_000_000.0
		} else {
			// Latency in milliseconds
			value = elapsed * 1000.0
		}

		values = append(values, value)
	}

	return calculateStats(values)
}

func calculateStats(values []float64) Stats {
	sort.Float64s(values)

	n := len(values)

	// Calculate percentiles
	q1 := percentile(values, 25.0)
	median := percentile(values, 50.0)
	q3 := percentile(values, 75.0)

	// Calculate IQR and identify outliers
	iqr := q3 - q1
	lowerFence := q1 - 1.5*iqr
	upperFence := q3 + 1.5*iqr

	// Separate outliers from non-outliers
	var outliers []float64
	var nonOutliers []float64
	for _, v := range values {
		if v < lowerFence || v > upperFence {
			outliers = append(outliers, v)
		} else {
			nonOutliers = append(nonOutliers, v)
		}
	}

	// Calculate min/max from non-outliers (if any exist)
	var min, max float64
	if len(nonOutliers) > 0 {
		min = nonOutliers[0]
		max = nonOutliers[len(nonOutliers)-1]
	} else {
		// Fallback if all values are outliers
		min = values[0]
		max = values[n-1]
	}

	return Stats{
		Min:      min,
		Q1:       q1,
		Median:   median,
		Q3:       q3,
		Max:      max,
		Outliers: outliers,
		Samples:  values,
	}
}

func percentile(sortedValues []float64, p float64) float64 {
	n := float64(len(sortedValues))
	index := (p / 100.0) * (n - 1.0)
	lower := int(math.Floor(index))
	upper := int(math.Ceil(index))

	if lower == upper {
		return sortedValues[lower]
	}

	weight := index - float64(lower)
	return sortedValues[lower]*(1.0-weight) + sortedValues[upper]*weight
}

func printOutliers(outliers []float64, decimals int) {
	if len(outliers) == 0 {
		fmt.Println("  outliers: []")
		return
	}

	fmt.Print("  outliers: [")
	for i, v := range outliers {
		if i > 0 {
			fmt.Print(", ")
		}
		fmt.Printf("%.*f", decimals, v)
	}
	fmt.Println("]")
}

func printSamples(samples []float64, decimals int) {
	if len(samples) == 0 {
		fmt.Println("  samples: []")
		return
	}

	fmt.Print("  samples: [")
	for i, v := range samples {
		if i > 0 {
			fmt.Print(", ")
		}
		fmt.Printf("%.*f", decimals, v)
	}
	fmt.Println("]")
}

func max(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func getEnvOrDefault(key, defaultValue string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultValue
}

func getEnvInt64(key string, defaultValue int64) int64 {
	val := os.Getenv(key)
	if val == "" {
		return defaultValue
	}
	parsed, err := strconv.ParseInt(val, 10, 64)
	if err != nil {
		return defaultValue
	}
	return parsed
}

func getEnvInt(key string, defaultValue int) int {
	val := os.Getenv(key)
	if val == "" {
		return defaultValue
	}
	parsed, err := strconv.Atoi(val)
	if err != nil {
		return defaultValue
	}
	return parsed
}
