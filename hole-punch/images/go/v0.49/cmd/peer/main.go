// Peer for hole-punch tests. Runs as either the dialer or the listener.

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/muxer/yamux"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	"github.com/libp2p/go-libp2p/p2p/protocol/holepunch"
	"github.com/libp2p/go-libp2p/p2p/protocol/ping"
	"github.com/libp2p/go-libp2p/p2p/security/noise"
	libp2ptls "github.com/libp2p/go-libp2p/p2p/security/tls"
	libp2pquic "github.com/libp2p/go-libp2p/p2p/transport/quic"
	"github.com/libp2p/go-libp2p/p2p/transport/tcp"
	ma "github.com/multiformats/go-multiaddr"
	"github.com/redis/go-redis/v9"
)

// testTimeout bounds the whole run. The harness kills the stack at 180s, so the
// peer exits first with a status the harness can attribute.
const testTimeout = 150 * time.Second

// pingSize is the byte length of the payload echoed back over the hole-punched connection.
const pingSize = 32

func main() {
	log.SetFlags(0)
	log.SetPrefix("peer: ")

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

	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	rdb := redis.NewClient(&redis.Options{Addr: cfg.RedisAddr})
	defer rdb.Close()

	if err := waitForRedis(ctx, rdb); err != nil {
		return err
	}

	relayAddr, err := waitForValue(ctx, rdb, cfg.relayMultiaddrKey())
	if err != nil {
		return fmt.Errorf("waiting for relay multiaddr: %w", err)
	}
	log.Printf("relay multiaddr: %s", relayAddr)

	relayMaddr, err := ma.NewMultiaddr(relayAddr)
	if err != nil {
		return fmt.Errorf("parsing relay multiaddr %q: %w", relayAddr, err)
	}
	relayInfo, err := peer.AddrInfoFromP2pAddr(relayMaddr)
	if err != nil {
		return fmt.Errorf("extracting relay peer info: %w", err)
	}

	tracer := newHolePunchTracer()

	h, err := newHost(cfg, tracer)
	if err != nil {
		return fmt.Errorf("creating host: %w", err)
	}
	defer h.Close()

	log.Printf("peer id: %s", h.ID())
	log.Printf("listening on: %v", h.Addrs())

	if err := connectToRelay(ctx, h, *relayInfo); err != nil {
		return err
	}

	if cfg.IsDialer {
		return runDialer(ctx, cfg, h, rdb, relayMaddr, tracer)
	}
	return runListener(ctx, cfg, h, rdb, *relayInfo)
}

// runListener reserves a slot on the relay, publishes its peer id and then
// serves until Docker stops the container.
func runListener(ctx context.Context, cfg *Config, h host.Host, rdb *redis.Client, relayInfo peer.AddrInfo) error {
	if err := reserve(ctx, h, relayInfo); err != nil {
		return err
	}

	if err := waitForDCUtR(ctx, h); err != nil {
		return err
	}

	key := cfg.listenerPeerIDKey()
	if err := rdb.Set(ctx, key, h.ID().String(), 0).Err(); err != nil {
		return fmt.Errorf("publishing peer id to %s: %w", key, err)
	}
	log.Printf("published peer id to redis (key: %s)", key)

	// The dialer exits first and docker-compose tears the stack down, so there
	// is no completion condition to wait on here.
	<-ctx.Done()
	return nil
}

// runDialer connects to the listener through the relay, waits for DCUtR to
// upgrade the connection to a direct one and reports the timings on stdout.
func runDialer(ctx context.Context, cfg *Config, h host.Host, rdb *redis.Client, relayMaddr ma.Multiaddr, tracer *holePunchTracer) error {
	listenerID, err := waitForValue(ctx, rdb, cfg.listenerPeerIDKey())
	if err != nil {
		return fmt.Errorf("waiting for listener peer id: %w", err)
	}

	listenerPeerID, err := peer.Decode(listenerID)
	if err != nil {
		return fmt.Errorf("decoding listener peer id %q: %w", listenerID, err)
	}
	log.Printf("listener peer id: %s", listenerPeerID)

	circuitAddr, err := ma.NewMultiaddr("/p2p-circuit/p2p/" + listenerPeerID.String())
	if err != nil {
		return fmt.Errorf("building circuit multiaddr: %w", err)
	}
	circuitAddr = relayMaddr.Encapsulate(circuitAddr)
	log.Printf("dialling listener through relay: %s", circuitAddr)

	// The listener starts the exchange as soon as the circuit opens, so the
	// dialer waits for its /libp2p/dcutr handler before opening the circuit.
	if err := waitForDCUtR(ctx, h); err != nil {
		return err
	}

	// The measurement starts here so that it covers the relayed dial and the
	// DCUtR exchange it triggers, but not the earlier relay setup.
	start := time.Now()

	if err := h.Connect(ctx, peer.AddrInfo{
		ID:    listenerPeerID,
		Addrs: []ma.Multiaddr{circuitAddr},
	}); err != nil {
		return fmt.Errorf("connecting through relay: %w", err)
	}
	log.Printf("relayed connection established")

	if err := waitForDirectConn(ctx, h, listenerPeerID, tracer); err != nil {
		return err
	}
	dcutrElapsed := time.Since(start)
	log.Printf("direct connection established after %.2fms", millis(dcutrElapsed))

	pingRTT, err := pingDirect(ctx, h, listenerPeerID)
	if err != nil {
		return err
	}
	log.Printf("ping over direct connection: %.2fms", millis(pingRTT))

	fmt.Println(latencyReport(dcutrElapsed, pingRTT))
	return nil
}

// waitForDirectConn blocks until DCUtR reports success or a non-relayed
// connection to the peer appears.
//
// Both conditions are watched because go-libp2p only reports a hole punch
// through the tracer when the DCUtR exchange runs. If the holepuncher's initial
// direct dial happens to succeed, no hole punch is traced even though the
// connection is now direct, and the test should still pass.
func waitForDirectConn(ctx context.Context, h host.Host, pid peer.ID, tracer *holePunchTracer) error {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()

	for {
		if directConn(h, pid) != nil {
			return nil
		}

		select {
		case <-ctx.Done():
			return errors.New("timed out waiting for a direct connection")
		case err := <-tracer.failed:
			return fmt.Errorf("hole punch failed: %w", err)
		case <-tracer.succeeded:
			if directConn(h, pid) == nil {
				return errors.New("hole punch reported success but no direct connection exists")
			}
			return nil
		case <-ticker.C:
		}
	}
}

// directConn returns a connection to the peer that does not run over the relay.
func directConn(h host.Host, pid peer.ID) network.Conn {
	for _, conn := range h.Network().ConnsToPeer(pid) {
		if !conn.Stat().Limited {
			return conn
		}
	}
	return nil
}

// pingDirect echoes a payload off the peer and returns the round-trip time.
//
// The ping service is not used because this has to fail rather than fall back
// when the connection is still relayed, and the returned stream is checked to
// confirm which connection carried it.
func pingDirect(ctx context.Context, h host.Host, pid peer.ID) (time.Duration, error) {
	s, err := h.NewStream(ctx, pid, ping.ID)
	if err != nil {
		return 0, fmt.Errorf("opening ping stream: %w", err)
	}
	defer s.Close()

	if s.Conn().Stat().Limited {
		return 0, errors.New("hole punch failed: ping stream is still relayed")
	}
	log.Printf("ping stream runs over %s", s.Conn().RemoteMultiaddr())

	sent := make([]byte, pingSize)
	if _, err := rand.Read(sent); err != nil {
		return 0, fmt.Errorf("generating ping payload: %w", err)
	}

	start := time.Now()
	if _, err := s.Write(sent); err != nil {
		return 0, fmt.Errorf("writing ping: %w", err)
	}

	received := make([]byte, pingSize)
	if _, err := io.ReadFull(s, received); err != nil {
		return 0, fmt.Errorf("reading ping response: %w", err)
	}
	rtt := time.Since(start)

	if !bytes.Equal(sent, received) {
		return 0, errors.New("ping response did not match the payload sent")
	}
	return rtt, nil
}

// waitForDCUtR blocks until the hole punch service has registered its stream
// handler, which it does at the same moment it starts watching for relayed
// connections.
//
// go-libp2p defers both until the host has observed a public address for
// itself, and the watcher only ever sees connections opened after it starts. A
// dialer arriving over the circuit before that point reaches a peer that will
// never begin the exchange, so the listener holds its peer id back until the
// handler is in place.
func waitForDCUtR(ctx context.Context, h host.Host) error {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()

	for {
		for _, p := range h.Mux().Protocols() {
			if p == holepunch.Protocol {
				log.Printf("hole punch service ready")
				return nil
			}
		}

		select {
		case <-ctx.Done():
			return errors.New("timed out waiting for the hole punch service to start")
		case <-ticker.C:
		}
	}
}

// reserve takes a relay slot so the dialer can reach this peer over a circuit.
//
// The reservation is made directly rather than through autorelay, which builds
// circuit addresses only from a relay's public addresses. Every address in this
// harness is in a private range, so autorelay does not derive a circuit address and
// never reports a reservation, however readily the relay grants one.
func reserve(ctx context.Context, h host.Host, relayInfo peer.AddrInfo) error {
	reservation, err := client.Reserve(ctx, h, relayInfo)
	if err != nil {
		return fmt.Errorf("reserving a relay slot: %w", err)
	}

	log.Printf("relay reservation accepted, expires %s, vouched addrs %v",
		reservation.Expiration.Format(time.RFC3339), reservation.Addrs)
	return nil
}

func connectToRelay(ctx context.Context, h host.Host, relayInfo peer.AddrInfo) error {
	for attempt := 1; ; attempt++ {
		err := h.Connect(ctx, relayInfo)
		if err == nil {
			log.Printf("connected to relay %s", relayInfo.ID)
			return nil
		}
		log.Printf("connecting to relay (attempt %d): %v", attempt, err)

		select {
		case <-ctx.Done():
			return fmt.Errorf("connecting to relay: %w", err)
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func newHost(cfg *Config, tracer *holePunchTracer) (host.Host, error) {
	listenAddr, err := cfg.listenAddr()
	if err != nil {
		return nil, err
	}

	opts := []libp2p.Option{
		libp2p.ListenAddrs(listenAddr),
		libp2p.EnableHolePunching(holepunch.WithTracer(tracer)),
		libp2p.EnableRelay(),
		// Both peers sit behind a NAT the harness built for them, so reachability
		// is forced to private instead of being discovered.
		libp2p.ForceReachabilityPrivate(),
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

// holePunchTracer reports the outcome of the DCUtR exchange to the dialer.
type holePunchTracer struct {
	succeeded chan struct{}
	failed    chan error
}

func newHolePunchTracer() *holePunchTracer {
	return &holePunchTracer{
		succeeded: make(chan struct{}, 1),
		failed:    make(chan error, 1),
	}
}

func (t *holePunchTracer) Trace(evt *holepunch.Event) {
	log.Printf("holepunch %s: %+v", evt.Type, evt.Evt)

	e, ok := evt.Evt.(*holepunch.EndHolePunchEvt)
	if !ok {
		return
	}

	if e.Success {
		select {
		case t.succeeded <- struct{}{}:
		default:
		}
		return
	}

	select {
	case t.failed <- errors.New(e.Error):
	default:
	}
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

// waitForValue polls until the key is set, since the peers reach this point in
// an order the harness does not control.
func waitForValue(ctx context.Context, rdb *redis.Client, key string) (string, error) {
	for {
		value, err := rdb.Get(ctx, key).Result()
		if err == nil {
			return value, nil
		}
		if !errors.Is(err, redis.Nil) {
			return "", err
		}

		select {
		case <-ctx.Done():
			return "", fmt.Errorf("timed out waiting for key %s", key)
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// latencyReport renders the measurements in the form run-single-test.sh greps
// out of the dialer's stdout.
func latencyReport(dcutr, pingRTT time.Duration) string {
	return fmt.Sprintf("latency:\n  handshake_plus_one_rtt: %.2f\n  ping_rtt: %.2f\n  unit: ms",
		millis(dcutr)+millis(pingRTT), millis(pingRTT))
}

func millis(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000.0
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
	IsDialer      bool
	RedisAddr     string
	TestKey       string
	Transport     string
	SecureChannel string
	Muxer         string
	ListenIP      string
}

func loadConfig(getenv func(string) string) (*Config, error) {
	cfg := &Config{
		RedisAddr:     getenv("REDIS_ADDR"),
		TestKey:       getenv("TEST_KEY"),
		Transport:     getenv("TRANSPORT"),
		SecureChannel: getenv("SECURE_CHANNEL"),
		Muxer:         getenv("MUXER"),
	}

	isDialer := getenv("IS_DIALER")
	if isDialer == "" {
		return nil, errors.New("IS_DIALER is not set")
	}
	var err error
	if cfg.IsDialer, err = strconv.ParseBool(isDialer); err != nil {
		return nil, fmt.Errorf("invalid IS_DIALER %q: %w", isDialer, err)
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

	if cfg.IsDialer {
		cfg.ListenIP = getenv("DIALER_IP")
	} else {
		cfg.ListenIP = getenv("LISTENER_IP")
	}
	if cfg.ListenIP == "" {
		cfg.ListenIP = "0.0.0.0"
	}

	return cfg, nil
}

func (c *Config) listenAddr() (ma.Multiaddr, error) {
	switch c.Transport {
	case transportTCP:
		return ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", c.ListenIP))
	case transportQUIC:
		return ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/udp/0/quic-v1", c.ListenIP))
	default:
		return nil, fmt.Errorf("unsupported transport %q", c.Transport)
	}
}

func (c *Config) relayMultiaddrKey() string {
	return c.TestKey + "_relay_multiaddr"
}

func (c *Config) listenerPeerIDKey() string {
	return c.TestKey + "_listener_peer_id"
}

func (c *Config) log() {
	log.Printf("IS_DIALER: %t", c.IsDialer)
	log.Printf("REDIS_ADDR: %s", c.RedisAddr)
	log.Printf("TEST_KEY: %s", c.TestKey)
	log.Printf("TRANSPORT: %s", c.Transport)
	log.Printf("SECURE_CHANNEL: %s", c.SecureChannel)
	log.Printf("MUXER: %s", c.Muxer)
	log.Printf("LISTEN_IP: %s", c.ListenIP)
	log.Printf("DEBUG: %t", c.Debug)
}
