package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/host/autonat"
	autonatpb "github.com/libp2p/go-libp2p/p2p/host/autonat/pb"
	"github.com/libp2p/go-msgio/pbio"
	ma "github.com/multiformats/go-multiaddr"
)

const autonatTimeout = 30 * time.Second

type RedisClient struct {
	addr string
}

func (c *RedisClient) Set(key, val string) error {
	conn, err := net.DialTimeout("tcp", c.addr, 5*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	cmd := fmt.Sprintf("*3\r\n$3\r\nSET\r\n$%d\r\n%s\r\n$%d\r\n%s\r\n", len(key), key, len(val), val)
	if _, err := conn.Write([]byte(cmd)); err != nil {
		return err
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		return err
	}
	if !strings.HasPrefix(line, "+OK") {
		return fmt.Errorf("unexpected redis response: %s", line)
	}
	return nil
}

func (c *RedisClient) Get(key string) (string, error) {
	conn, err := net.DialTimeout("tcp", c.addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	cmd := fmt.Sprintf("*2\r\n$3\r\nGET\r\n$%d\r\n%s\r\n", len(key), key)
	if _, err := conn.Write([]byte(cmd)); err != nil {
		return "", err
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(line, "$-1") {
		return "", nil
	}
	if strings.HasPrefix(line, "$") {
		var length int
		if _, err := fmt.Sscanf(line, "$%d", &length); err != nil {
			return "", err
		}
		buf := make([]byte, length)
		if _, err := io.ReadFull(r, buf); err != nil {
			return "", err
		}
		return string(buf), nil
	}
	return "", fmt.Errorf("unexpected redis response: %s", line)
}

func getContainerIP(redisAddr string) string {
	conn, err := net.Dial("udp", redisAddr)
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

func peerMultiaddr(h host.Host) string {
	for _, a := range h.Addrs() {
		return fmt.Sprintf("%s/p2p/%s", a.String(), h.ID().String())
	}
	return ""
}

func waitForKey(r *RedisClient, key string, timeout time.Duration) string {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if val, _ := r.Get(key); val != "" {
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

// serveAutonat implements the server side of /ipfs/autonat/1.0.0: read a
// DIAL request, dial the requester back, and report the outcome.
func serveAutonat(h host.Host) {
	h.SetStreamHandler(autonat.AutoNATProto, func(s network.Stream) {
		defer s.Close()
		r := pbio.NewDelimitedReader(s, network.MessageSizeMax)
		w := pbio.NewDelimitedWriter(s)

		var req autonatpb.Message
		if err := r.ReadMsg(&req); err != nil {
			return
		}
		if req.GetType() != autonatpb.Message_DIAL || req.GetDial() == nil {
			return
		}

		resp := &autonatpb.Message{
			Type: autonatpb.Message_DIAL_RESPONSE.Enum(),
		}
		dialResp := &autonatpb.Message_DialResponse{}

		peerID, err := peer.IDFromBytes(req.GetDial().GetPeer().GetId())
		dialCtx, cancel := context.WithTimeout(context.Background(), autonatTimeout)
		defer cancel()
		if err == nil {
			var addrs []ma.Multiaddr
			for _, ab := range req.GetDial().GetPeer().GetAddrs() {
				if a, err := ma.NewMultiaddrBytes(ab); err == nil {
					addrs = append(addrs, a)
				}
			}
			if err := h.Connect(dialCtx, peer.AddrInfo{ID: peerID, Addrs: addrs}); err == nil {
				dialResp.Status = autonatpb.Message_OK.Enum()
				if len(addrs) > 0 {
					dialResp.Addr = addrs[0].Bytes()
				}
			} else {
				dialResp.Status = autonatpb.Message_E_DIAL_ERROR.Enum()
			}
		} else {
			dialResp.Status = autonatpb.Message_E_DIAL_ERROR.Enum()
		}
		resp.DialResponse = dialResp
		_ = w.WriteMsg(resp)
	})
}

func runServer(ctx context.Context, h host.Host, r *RedisClient, testKey string) int {
	serveAutonat(h)

	serverKey := fmt.Sprintf("%s_server_addr", testKey)
	if err := r.Set(serverKey, peerMultiaddr(h)); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to write server addr to redis: %v\n", err)
		return 1
	}
	fmt.Printf("AutoNAT server ready at %s\n", peerMultiaddr(h))

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-sigCh:
	case <-ctx.Done():
	}
	return 0
}

func runClient(ctx context.Context, h host.Host, r *RedisClient, testKey string) int {
	fail := func(format string, args ...any) int {
		msg := fmt.Sprintf(format, args...)
		fmt.Printf("error: %s\n", msg)
		fmt.Println("status: fail")
		return 1
	}

	serverAddr := waitForKey(r, fmt.Sprintf("%s_server_addr", testKey), 60*time.Second)
	if serverAddr == "" {
		return fail("Timeout waiting for server address")
	}
	serverInfo := mustAddrInfo(serverAddr)

	connectCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	if err := h.Connect(connectCtx, *serverInfo); err != nil {
		cancel()
		return fail("Failed to connect to server: %v", err)
	}
	cancel()

	client := autonat.NewAutoNATClient(h, nil, nil)
	dialCtx, dialCancel := context.WithTimeout(ctx, autonatTimeout)
	defer dialCancel()
	if err := client.DialBack(dialCtx, serverInfo.ID); err != nil {
		return fail("Server could not dial us back: %v", err)
	}

	fmt.Println("verdict: 0")
	fmt.Println("status: pass")
	return 0
}

func main() {
	role := os.Getenv("ROLE")
	redisAddr := os.Getenv("REDIS_ADDR")
	testKey := os.Getenv("TEST_KEY")

	if role == "" || redisAddr == "" || testKey == "" {
		fmt.Fprintln(os.Stderr, "Required env vars: ROLE, REDIS_ADDR, TEST_KEY")
		os.Exit(1)
	}

	r := &RedisClient{addr: redisAddr}
	containerIP := getContainerIP(redisAddr)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	listenAddr, _ := ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", containerIP))
	h, err := libp2p.New(libp2p.ListenAddrs(listenAddr))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create host: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	fmt.Printf("Node started | role=%s addr=%s\n", role, peerMultiaddr(h))

	switch role {
	case "server":
		os.Exit(runServer(ctx, h, r, testKey))
	case "client":
		os.Exit(runClient(ctx, h, r, testKey))
	default:
		fmt.Fprintf(os.Stderr, "Unknown role: %s\n", role)
		os.Exit(1)
	}
}
