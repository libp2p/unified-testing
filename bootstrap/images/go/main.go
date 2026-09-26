package main

import (
	"context"
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
	"github.com/libp2p/go-libp2p/core/peerstore"
	"github.com/libp2p/go-libp2p/core/protocol"
	ma "github.com/multiformats/go-multiaddr"

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
//
// NOTE: libp2p has no bootstrap wire protocol on either stack — bootstrap is
// the *process* of learning a well-known peer, storing it, and (re)dialing
// it. The joiner below mirrors that process explicitly (parse → permanent
// peerstore → connect with retry → verify), matching what py-libp2p's
// BootstrapDiscovery does internally.

func runBootstrap(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	if err := r.Set(ctx, fmt.Sprintf("%s_bootstrap_addr", testKey), peerMultiaddr(h), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write bootstrap_addr to redis: %v\n", err)
		os.Exit(1)
	}
	if err := r.Set(ctx, fmt.Sprintf("%s_bootstrap_done", testKey), "1", 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write bootstrap_done to redis: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Bootstrap node ready at %s\n", peerMultiaddr(h))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runJoiner(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	waitCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	var bootstrapAddr string
	for bootstrapAddr == "" {
		val, err := r.Get(waitCtx, fmt.Sprintf("%s_bootstrap_addr", testKey)).Result()
		if err == nil && val != "" {
			bootstrapAddr = val
			break
		}
		select {
		case <-waitCtx.Done():
			fmt.Println("error: Timeout waiting for bootstrap_addr")
			fmt.Println("status: fail")
			os.Exit(1)
		case <-time.After(500 * time.Millisecond):
		}
	}
	fmt.Printf("Bootstrapping from %s\n", bootstrapAddr)

	maddr, err := ma.NewMultiaddr(bootstrapAddr)
	if err != nil {
		fmt.Printf("error: Invalid bootstrap multiaddr: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}
	info, err := peer.AddrInfoFromP2pAddr(maddr)
	if err != nil {
		fmt.Printf("error: Cannot extract AddrInfo: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	// Permanent peerstore entry, like a configured bootstrap peer.
	h.Peerstore().AddAddrs(info.ID, info.Addrs, peerstore.PermanentAddrTTL)

	// Connect with retry (mirrors the periodic reconnect loop).
	dialCtx, dialCancel := context.WithTimeout(ctx, 60*time.Second)
	defer dialCancel()
	connected := false
	for !connected {
		cctx, ccancel := context.WithTimeout(dialCtx, 10*time.Second)
		if err := h.Connect(cctx, *info); err != nil {
			ccancel()
			fmt.Printf("Bootstrap dial retry: %v\n", err)
			select {
			case <-dialCtx.Done():
				fmt.Println("error: Bootstrap did not connect in time")
				fmt.Println("status: fail")
				os.Exit(1)
			case <-time.After(2 * time.Second):
			}
			continue
		}
		ccancel()
		connected = true
	}
	fmt.Println("Bootstrap connection established, verifying with ping")

	pingCtx, pingCancel := context.WithTimeout(ctx, 15*time.Second)
	defer pingCancel()

	s, err := h.NewStream(pingCtx, info.ID, PingProto)
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
	case "bootstrap":
		runBootstrap(ctx, h, r, testKey)
	case "joiner":
		runJoiner(ctx, h, r, testKey)
	default:
		fmt.Fprintf(os.Stderr, "Unknown role: %s\n", role)
		os.Exit(1)
	}
}
