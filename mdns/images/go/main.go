package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	"github.com/libp2p/go-libp2p/p2p/discovery/mdns"
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

// discoveryNotifee forwards mDNS discoveries into a channel.
type discoveryNotifee struct {
	mu       sync.Mutex
	peers    map[peer.ID]peer.AddrInfo
	notifyCh chan peer.AddrInfo
}

func newNotifee() *discoveryNotifee {
	return &discoveryNotifee{
		peers:    make(map[peer.ID]peer.AddrInfo),
		notifyCh: make(chan peer.AddrInfo, 16),
	}
}

func (n *discoveryNotifee) HandlePeerFound(pi peer.AddrInfo) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if _, ok := n.peers[pi.ID]; ok {
		return
	}
	n.peers[pi.ID] = pi
	select {
	case n.notifyCh <- pi:
	default:
	}
}

// ─── Roles ───────────────────────────────────────────────────────────────────

func runAdvertiser(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	// Start mDNS broadcasting + listening (default service name for interop
	// with py-libp2p's "_p2p._udp.local.").
	notifee := newNotifee()
	mdnsSvc := mdns.NewMdnsService(h, mdns.ServiceName, notifee)
	defer mdnsSvc.Close()
	if err := mdnsSvc.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start mDNS service: %v\n", err)
		os.Exit(1)
	}

	if err := r.Set(ctx, fmt.Sprintf("%s_advertiser_id", testKey), h.ID().String(), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write advertiser_id to redis: %v\n", err)
		os.Exit(1)
	}
	if err := r.Set(ctx, fmt.Sprintf("%s_advertiser_done", testKey), "1", 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write advertiser_done to redis: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Advertiser ready at %s (broadcasting via mDNS)\n", peerMultiaddr(h))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runDiscoverer(ctx context.Context, h host.Host, r *redis.Client, testKey string) {
	// Wait for advertiser to be ready so we know which peer ID to expect.
	waitCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	var expectedID string
	for expectedID == "" {
		val, err := r.Get(waitCtx, fmt.Sprintf("%s_advertiser_id", testKey)).Result()
		if err == nil && val != "" {
			expectedID = val
			break
		}
		select {
		case <-waitCtx.Done():
			fmt.Println("error: Timeout waiting for advertiser_id")
			fmt.Println("status: fail")
			os.Exit(1)
		case <-time.After(500 * time.Millisecond):
		}
	}
	fmt.Printf("Expecting mDNS advertisement from %s\n", expectedID)

	notifee := newNotifee()
	mdnsSvc := mdns.NewMdnsService(h, mdns.ServiceName, notifee)
	defer mdnsSvc.Close()
	if err := mdnsSvc.Start(); err != nil {
		fmt.Printf("error: Failed to start mDNS service: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	// Wait for mDNS discovery of the expected peer.
	discoverCtx, discoverCancel := context.WithTimeout(ctx, 60*time.Second)
	defer discoverCancel()
	var target *peer.AddrInfo
waitLoop:
	for target == nil {
		select {
		case pi := <-notifee.notifyCh:
			fmt.Printf("mDNS discovered peer %s @ %v\n", pi.ID.String(), pi.Addrs)
			if pi.ID.String() == expectedID {
				cp := pi
				target = &cp
				break waitLoop
			}
		case <-discoverCtx.Done():
			break waitLoop
		case <-time.After(500 * time.Millisecond):
			// Also check map in case notification was missed (linear scan
			// by string compare: peer.ID string form is base58).
			notifee.mu.Lock()
			for id, pi := range notifee.peers {
				if id.String() == expectedID {
					cp := pi
					target = &cp
					break
				}
			}
			notifee.mu.Unlock()
		}
	}
	if target == nil {
		fmt.Println("error: Timeout waiting for mDNS discovery of advertiser")
		fmt.Println("status: fail")
		os.Exit(1)
	}

	dialCtx, dialCancel := context.WithTimeout(ctx, 15*time.Second)
	defer dialCancel()

	if err := h.Connect(dialCtx, *target); err != nil {
		fmt.Printf("error: Dial to advertiser failed: %v\n", err)
		fmt.Println("status: fail")
		os.Exit(1)
	}

	s, err := h.NewStream(dialCtx, target.ID, PingProto)
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
	case "advertiser":
		runAdvertiser(ctx, h, r, testKey)
	case "discoverer":
		runDiscoverer(ctx, h, r, testKey)
	default:
		fmt.Fprintf(os.Stderr, "Unknown role: %s\n", role)
		os.Exit(1)
	}
}
