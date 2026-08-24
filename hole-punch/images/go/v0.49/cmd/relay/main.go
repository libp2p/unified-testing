// Relay server for hole-punch tests.

package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/p2p/muxer/yamux"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	libp2ptls "github.com/libp2p/go-libp2p/p2p/security/tls"
	libp2pquic "github.com/libp2p/go-libp2p/p2p/transport/quic"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	ma "github.com/multiformats/go-multiaddr"
	manet "github.com/multiformats/go-multiaddr/net"
	"github.com/redis/go-redis/v9"
)

// startupTimeout bounds the time to reach the point where the relay is serving.
// After that the relay runs until Docker stops it.
const startupTimeout = 60 * time.Second

func main() {
	log.SetFlags(0)
	log.SetPrefix("relay: ")

	if err := run(); err != nil {
		log.Printf("FAILED: %v", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		return err
	}
	cfg.log()

	ctx, cancel := context.WithTimeout(context.Background(), startupTimeout)
	defer cancel()

	rdb := redis.NewClient(&redis.Options{Addr: cfg.RedisAddr})
	defer rdb.Close()

	if err := waitForRedis(ctx, rdb); err != nil {
		return err
	}

	h, err := newHost(cfg)
	if err != nil {
		return fmt.Errorf("creating host: %w", err)
	}
	defer h.Close()

	log.Printf("peer id: %s", h.ID())

	addr, err := reachableAddr(h)
	if err != nil {
		return err
	}
	fullAddr := fmt.Sprintf("%s/p2p/%s", addr, h.ID())
	log.Printf("listening on: %s", fullAddr)

	key := cfg.relayMultiaddrKey()
	if err := rdb.Set(ctx, key, fullAddr, 0).Err(); err != nil {
		return fmt.Errorf("publishing multiaddr to %s: %w", key, err)
	}
	log.Printf("published multiaddr to redis (key: %s)", key)

	log.Printf("relay ready, waiting for connections")

	// The dialer's exit tears the stack down, so the relay serves until Docker
	// signals it.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	return nil
}

// reachableAddr returns the address peers should use to dial the relay.
func reachableAddr(h host.Host) (ma.Multiaddr, error) {
	for _, addr := range h.Addrs() {
		if manet.IsIPLoopback(addr) {
			continue
		}
		return addr, nil
	}
	return nil, errors.New("no non-loopback listen address")
}

func newHost(cfg *Config) (host.Host, error) {
	listenAddr, err := cfg.listenAddr()
	if err != nil {
		return nil, err
	}

	opts := []libp2p.Option{
		libp2p.ListenAddrs(listenAddr),
		libp2p.EnableRelayService(),
		// The relay sits on the WAN side of both NATs on an address the harness
		// assigned, which go-libp2p would otherwise decline to advertise
		// because it falls in a private range. Without this the reservation
		// response has no addresses and clients reject it.
		libp2p.ForceReachabilityPublic(),
	}

	switch cfg.Transport {
	case transportTCP:
		opts = append(opts, libp2p.Transport(tcp.NewTCPTransport))
	case transportQUIC:
		opts = append(opts, libp2p.Transport(libp2pquic.NewTransport))
	default:
		return nil, fmt.Errorf("unsupported transport %q", cfg.Transport)
	}

	switch cfg.SecureChannel {
	case secureNoise:
		opts = append(opts, libp2p.Security(noise.ID, noise.New))
	case secureTLS:
		opts = append(opts, libp2p.Security(libp2ptls.ID, libp2ptls.New))
	case "":
	default:
		return nil, fmt.Errorf("unsupported secure channel %q", cfg.SecureChannel)
	}

	switch cfg.Muxer {
	case muxerYamux:
		opts = append(opts, libp2p.Muxer(yamux.ID, yamux.DefaultTransport))
	case "":
	default:
		return nil, fmt.Errorf("unsupported muxer %q", cfg.Muxer)
	}

	return libp2p.New(opts...)
}

func waitForRedis(ctx context.Context, rdb *redis.Client) error {
	for {
		if err := rdb.Ping(ctx).Err(); err == nil {
			return nil
		}

		select {
		case <-ctx.Done():
			return errors.New("timed out waiting for redis")
		case <-time.After(100 * time.Millisecond):
		}
	}
}

const (
	transportTCP  = "tcp"
	transportQUIC = "quic-v1"

	secureNoise = "noise"
	secureTLS   = "tls"

	muxerYamux = "yamux"
)

// Config holds the test parameters the harness passes in the environment.
type Config struct {
	Debug         bool
	RedisAddr     string
	TestKey       string
	Transport     string
	SecureChannel string
	Muxer         string
	RelayIP       string
}

func loadConfig(getenv func(string) string) (*Config, error) {
	cfg := &Config{
		RedisAddr:     getenv("REDIS_ADDR"),
		TestKey:       getenv("TEST_KEY"),
		Transport:     getenv("TRANSPORT"),
		SecureChannel: getenv("SECURE_CHANNEL"),
		Muxer:         getenv("MUXER"),
		RelayIP:       getenv("RELAY_IP"),
	}

	if debug := getenv("DEBUG"); debug != "" {
		cfg.Debug, _ = strconv.ParseBool(debug)
	}

	if cfg.RedisAddr == "" {
		return nil, errors.New("REDIS_ADDR is not set")
	}
	if cfg.TestKey == "" {
		return nil, errors.New("TEST_KEY is not set")
	}

	switch cfg.Transport {
	case transportTCP, transportQUIC:
	case "":
		return nil, errors.New("TRANSPORT is not set")
	default:
		return nil, fmt.Errorf("unsupported transport %q", cfg.Transport)
	}

	// The harness leaves both unset for standalone transports such as quic-v1.
	switch cfg.SecureChannel {
	case secureNoise, secureTLS, "":
	default:
		return nil, fmt.Errorf("unsupported secure channel %q", cfg.SecureChannel)
	}
	switch cfg.Muxer {
	case muxerYamux, "":
	default:
		return nil, fmt.Errorf("unsupported muxer %q", cfg.Muxer)
	}

	if cfg.RelayIP == "" {
		cfg.RelayIP = "0.0.0.0"
	}

	return cfg, nil
}

func (c *Config) listenAddr() (ma.Multiaddr, error) {
	switch c.Transport {
	case transportTCP:
		return ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", c.RelayIP))
	case transportQUIC:
		return ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/udp/0/quic-v1", c.RelayIP))
	default:
		return nil, fmt.Errorf("unsupported transport %q", c.Transport)
	}
}

func (c *Config) relayMultiaddrKey() string {
	return c.TestKey + "_relay_multiaddr"
}

func (c *Config) log() {
	log.Printf("REDIS_ADDR: %s", c.RedisAddr)
	log.Printf("TEST_KEY: %s", c.TestKey)
	log.Printf("TRANSPORT: %s", c.Transport)
	log.Printf("SECURE_CHANNEL: %s", c.SecureChannel)
	log.Printf("MUXER: %s", c.Muxer)
	log.Printf("RELAY_IP: %s", c.RelayIP)
	log.Printf("DEBUG: %t", c.Debug)
}
