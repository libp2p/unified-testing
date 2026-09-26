package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	relayclient "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	ma "github.com/multiformats/go-multiaddr"

	"github.com/redis/go-redis/v9"
)

const EchoProto = protocol.ID("/relay-echo/1.0.0")

var echoMsg = []byte("hello-relay")

// ─── libp2p host helpers ──────────────────────────────────────────────────────

func getContainerIP(redisAddr string) string {
	conn, err := net.Dial("udp", redisAddr)
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

func echoHandler(s network.Stream) {
	defer s.Close()
	// Fixed-length echo: read exactly len(echoMsg), write it back.
	buf := make([]byte, len(echoMsg))
	if _, err := io.ReadFull(s, buf); err != nil {
		return
	}
	if _, err := s.Write(buf); err != nil {
		return
	}
}

func makeHost(ip string, opts ...libp2p.Option) (host.Host, error) {
	listenAddr, _ := ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", ip))
	opts = append([]libp2p.Option{libp2p.ListenAddrs(listenAddr)}, opts...)
	h, err := libp2p.New(opts...)
	if err != nil {
		return nil, err
	}
	h.SetStreamHandler(EchoProto, echoHandler)
	return h, nil
}

func peerMultiaddr(h host.Host) string {
	for _, a := range h.Addrs() {
		return fmt.Sprintf("%s/p2p/%s", a.String(), h.ID().String())
	}
	return ""
}

// ─── Roles ────────────────────────────────────────────────────────────────────

func runRelay(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	res := relayv2.DefaultResources()
	relaySvc, err := relayv2.New(h, relayv2.WithResources(res))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start relay service: %v\n", err)
		os.Exit(1)
	}
	defer relaySvc.Close()

	relayKey := fmt.Sprintf("%s_relay_multiaddr", testKey)
	if err := r.Set(ctx, relayKey, peerMultiaddr(h), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to publish relay multiaddr: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Relay ready at %s\n", peerMultiaddr(h))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runListener(ctx context.Context, h host.Host, relayInfo *peer.AddrInfo, r *redis.Client, testKey string) {
	// Explicitly reserve a relay slot (retry while the relay is starting).
	var rsvp *relayclient.Reservation
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		resCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		var err error
		rsvp, err = relayclient.Reserve(resCtx, h, *relayInfo)
		cancel()
		if err == nil {
			break
		}
		fmt.Printf("Reserve retry: %v\n", err)
		time.Sleep(2 * time.Second)
	}
	if rsvp == nil {
		fmt.Println("error: Failed to reserve relay slot")
		fmt.Println("status: fail")
		os.Exit(1)
	}
	// Listener stays alive holding its reservation; the dialer verifies
	// connectivity through the circuit.
	listenerKey := fmt.Sprintf("%s_listener_peer_id", testKey)
	if err := r.Set(ctx, listenerKey, h.ID().String(), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to publish listener peer ID: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Listener %s reserved, waiting for dialer...\n", h.ID().String())

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runDialer(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	relayKey := fmt.Sprintf("%s_relay_multiaddr", testKey)
	listenerKey := fmt.Sprintf("%s_listener_peer_id", testKey)

	relayAddr := waitForKey(ctx, r, relayKey, 60*time.Second)
	if relayAddr == "" {
		fmt.Println("error: Timeout waiting for relay multiaddr")
		fmt.Println("status: fail")
		os.Exit(1)
	}
	listenerIDStr := waitForKey(ctx, r, listenerKey, 60*time.Second)
	if listenerIDStr == "" {
		fmt.Println("error: Timeout waiting for listener peer ID")
		fmt.Println("status: fail")
		os.Exit(1)
	}
	listenerID, err := peer.Decode(listenerIDStr)
	if err != nil {
		fmt.Printf("error: Bad listener peer ID: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	// Dial the listener through the relay circuit, retrying while the
	// listener's reservation propagates.
	circuitAddrStr := fmt.Sprintf("%s/p2p-circuit/p2p/%s", relayAddr, listenerIDStr)
	circuitMA, err := ma.NewMultiaddr(circuitAddrStr)
	if err != nil {
		fmt.Printf("error: Bad circuit address: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	target := peer.AddrInfo{ID: listenerID, Addrs: []ma.Multiaddr{circuitMA}}

	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := h.Connect(dialCtx, target)
		cancel()
		if err == nil {
			break
		}
		fmt.Printf("Circuit dial retry: %v\n", err)
		time.Sleep(2 * time.Second)
	}

	streamCtx, streamCancel := context.WithTimeout(ctx, 15*time.Second)
	defer streamCancel()
	// Relayed connections are "limited": streams require explicit opt-in.
	streamCtx = network.WithAllowLimitedConn(streamCtx, "relay-echo")
	s, err := h.NewStream(streamCtx, listenerID, EchoProto)
	if err != nil {
		fmt.Printf("error: Open echo stream failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	defer s.Close()

	msg := echoMsg
	if _, err := s.Write(msg); err != nil {
		fmt.Printf("error: Write echo failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	reply := make([]byte, len(msg))
	if _, err := io.ReadFull(s, reply); err != nil {
		fmt.Printf("error: Read echo failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	if string(reply) == string(msg) {
		fmt.Println("status: pass")
		os.Exit(0)
	}
	fmt.Printf("error: Unexpected echo: %q\n", string(reply))
	fmt.Println("status: fail")
	os.Exit(1)
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func redisGet(ctx context.Context, r *redis.Client, key string) (string, error) {
	val, err := r.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil // key not found
	}
	return val, err
}

func waitForKey(ctx context.Context, r *redis.Client, key string, timeout time.Duration) string {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		val, _ := redisGet(ctx, r, key)
		if val != "" {
			return val
		}
		time.Sleep(500 * time.Millisecond)
	}
	return ""
}

func mustAddrInfo(addrStr string) *peer.AddrInfo {
	maddr, err := ma.NewMultiaddr(addrStr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to parse multiaddr %q: %v\n", addrStr, err)
		os.Exit(1)
	}
	info, err := peer.AddrInfoFromP2pAddr(maddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to extract AddrInfo from %q: %v\n", addrStr, err)
		os.Exit(1)
	}
	return info
}

// ─── Entry point ──────────────────────────────────────────────────────────────

func main() {
	role := os.Getenv("ROLE")
	redisAddr := os.Getenv("REDIS_ADDR")
	testKey := os.Getenv("TEST_KEY")

	if role == "" || redisAddr == "" || testKey == "" {
		fmt.Fprintln(os.Stderr, "Required env vars: ROLE, REDIS_ADDR, TEST_KEY")
		os.Exit(1)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	r := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer r.Close()

	containerIP := getContainerIP(redisAddr)

	var h host.Host
	var err error
	var relayInfo *peer.AddrInfo
	if role == "listener" || role == "dialer" {
		relayAddr := waitForKey(ctx, r, fmt.Sprintf("%s_relay_multiaddr", testKey), 60*time.Second)
		if relayAddr == "" {
			fmt.Println("error: Timeout waiting for relay multiaddr")
			fmt.Println("status: fail")
			os.Exit(1)
		}
		relayInfo = mustAddrInfo(relayAddr)
	}
	h, err = makeHost(containerIP)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create host: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	if relayInfo != nil {
		connCtx, connCancel := context.WithTimeout(ctx, 30*time.Second)
		if err := h.Connect(connCtx, *relayInfo); err != nil {
			connCancel()
			fmt.Fprintf(os.Stderr, "Failed to connect to relay: %v\n", err)
			os.Exit(1)
		}
		connCancel()
	}

	fmt.Printf("Node started | role=%s addr=%s\n", role, peerMultiaddr(h))

	switch role {
	case "relay":
		runRelay(ctx, h, r, testKey)
	case "listener":
		runListener(ctx, h, relayInfo, r, testKey)
	case "dialer":
		runDialer(ctx, h, r, testKey)
	default:
		fmt.Fprintf(os.Stderr, "Unknown role: %s\n", role)
		os.Exit(1)
	}
}
