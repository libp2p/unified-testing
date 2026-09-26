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
	ma "github.com/multiformats/go-multiaddr"

	rendezvous "github.com/berty/go-libp2p-rendezvous"
	db "github.com/berty/go-libp2p-rendezvous/db/sqlite"

	"github.com/redis/go-redis/v9"
)

const PingProto = protocol.ID("/ping/1.0.0")

// ─── libp2p host helpers ──────────────────────────────────────────────────────

func getContainerIP(redisAddr string) string {
	conn, err := net.Dial("udp", redisAddr)
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

func makeHost(ip string) (host.Host, error) {
	listenAddr, _ := ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", ip))
	h, err := libp2p.New(
		libp2p.ListenAddrs(listenAddr),
	)
	if err != nil {
		return nil, err
	}

	// ping responder (used by discoverer to verify reachability)
	h.SetStreamHandler(PingProto, func(s network.Stream) {
		buf := make([]byte, 4)
		if _, err := io.ReadFull(s, buf); err != nil {
			s.Reset()
			return
		}
		if string(buf) == "ping" {
			_, _ = s.Write([]byte("pong"))
		}
		s.Close()
	})

	return h, nil
}

func peerMultiaddr(h host.Host) string {
	for _, a := range h.Addrs() {
		return fmt.Sprintf("%s/p2p/%s", a.String(), h.ID().String())
	}
	return ""
}

// ─── Roles ───────────────────────────────────────────────────────────────────

func runServer(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	dbi, err := db.OpenDB(ctx, ":memory:")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to open sqlite db: %v\n", err)
		os.Exit(1)
	}
	defer dbi.Close()

	_ = rendezvous.NewRendezvousService(h, dbi)

	serverKey := fmt.Sprintf("%s_server_addr", testKey)
	if err := r.Set(ctx, serverKey, peerMultiaddr(h), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write server addr to redis: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Rendezvous server ready at %s\n", peerMultiaddr(h))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runRegistrant(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	serverKey := fmt.Sprintf("%s_server_addr", testKey)
	serverAddr := waitForKey(ctx, r, serverKey, 60*time.Second)
	if serverAddr == "" {
		fmt.Fprintf(os.Stderr, "Timeout waiting for server address\n")
		os.Exit(1)
	}

	serverInfo := mustAddrInfo(serverAddr)
	connectCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	if err := h.Connect(connectCtx, *serverInfo); err != nil {
		cancel()
		fmt.Fprintf(os.Stderr, "Failed to connect to rendezvous server: %v\n", err)
		os.Exit(1)
	}
	cancel()

	rp := rendezvous.NewRendezvousPoint(h, serverInfo.ID)
	ns := fmt.Sprintf("rendezvous-ns-%s", testKey)
	grantedTTL, err := rp.Register(ctx, ns, 300)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to register: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Registered in namespace %q with TTL %v\n", ns, grantedTTL)

	if err := r.Set(ctx, fmt.Sprintf("%s_registrant_id", testKey), h.ID().String(), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write registrant_id to redis: %v\n", err)
		os.Exit(1)
	}
	if err := r.Set(ctx, fmt.Sprintf("%s_registrant_done", testKey), "1", 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write registrant_done to redis: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Registrant waiting for discoverer...")
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runDiscoverer(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	serverKey := fmt.Sprintf("%s_server_addr", testKey)
	regDoneKey := fmt.Sprintf("%s_registrant_done", testKey)

	// wait for both server and registrant to be ready (context-aware: a
	// cancelled parent context aborts the wait instead of sleeping through it)
	waitCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	var serverAddr, regDone string
waitLoop:
	for serverAddr == "" || regDone == "" {
		if serverAddr == "" {
			if val, err := redisGet(waitCtx, r, serverKey); err == nil {
				serverAddr = val
			} else if waitCtx.Err() == nil {
				fmt.Fprintf(os.Stderr, "warning: redis GET %q failed: %v\n", serverKey, err)
			}
		}
		if regDone == "" {
			if val, err := redisGet(waitCtx, r, regDoneKey); err == nil {
				regDone = val
			} else if waitCtx.Err() == nil {
				fmt.Fprintf(os.Stderr, "warning: redis GET %q failed: %v\n", regDoneKey, err)
			}
		}
		if serverAddr != "" && regDone != "" {
			break
		}
		select {
		case <-waitCtx.Done():
			break waitLoop
		case <-ticker.C:
		}
	}
	if serverAddr == "" || regDone == "" {
		fmt.Println("error: Timeout waiting for server and registrant")
		fmt.Println("status: fail")
		os.Exit(1)
	}

	expectedID, _ := redisGet(ctx, r, fmt.Sprintf("%s_registrant_id", testKey))

	serverInfo := mustAddrInfo(serverAddr)
	connectCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	if err := h.Connect(connectCtx, *serverInfo); err != nil {
		cancel()
		fmt.Printf("error: Failed to connect to server: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	cancel()

	rp := rendezvous.NewRendezvousPoint(h, serverInfo.ID)
	ns := fmt.Sprintf("rendezvous-ns-%s", testKey)
	regs, _, err := rp.Discover(ctx, ns, 100, nil)
	if err != nil {
		fmt.Printf("error: Discover failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	fmt.Printf("Discovered %d peer(s)\n", len(regs))

	var target *rendezvous.Registration
	for i := range regs {
		if regs[i].Peer.ID.String() == expectedID {
			target = &regs[i]
			break
		}
	}
	if target == nil {
		fmt.Printf("error: Expected peer %s not found in discovery results\n", expectedID)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	dialCtx, dialCancel := context.WithTimeout(ctx, 10*time.Second)
	defer dialCancel()

	if err := h.Connect(dialCtx, target.Peer); err != nil {
		fmt.Printf("error: Dial to registrant failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	s, err := h.NewStream(dialCtx, target.Peer.ID, PingProto)
	if err != nil {
		fmt.Printf("error: Open stream failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	defer s.Close()

	if _, err := s.Write([]byte("ping")); err != nil {
		fmt.Printf("error: Write ping failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	buf := make([]byte, 4)
	if _, err := io.ReadFull(s, buf); err != nil {
		fmt.Printf("error: Read pong failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	if string(buf) == "pong" {
		fmt.Println("status: pass")
		os.Exit(0)
	}
	fmt.Printf("error: Unexpected response: %s\n", string(buf))
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
	waitCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		if val, err := redisGet(waitCtx, r, key); err == nil && val != "" {
			return val
		} else if err != nil && waitCtx.Err() == nil {
			fmt.Fprintf(os.Stderr, "warning: redis GET %q failed: %v\n", key, err)
		}
		select {
		case <-waitCtx.Done():
			return ""
		case <-ticker.C:
		}
	}
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

// ─── Entry point ─────────────────────────────────────────────────────────────

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

	h, err := makeHost(containerIP)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create host: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	fmt.Printf("Node started | role=%s addr=%s\n", role, peerMultiaddr(h))

	switch role {
	case "server":
		runServer(ctx, h, r, testKey)
	case "registrant":
		runRegistrant(ctx, h, r, testKey)
	case "discoverer":
		runDiscoverer(ctx, h, r, testKey)
	default:
		fmt.Fprintf(os.Stderr, "Unknown role: %s\n", role)
		os.Exit(1)
	}
}
