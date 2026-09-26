package main

// Go hole-punch interop peer (mirrors the nim/rust/py peers).
//
// NOTE: this peer implements DCUtR manually instead of using go-libp2p's
// holepunch service: the service only starts with a *public* observed
// address plus non-private AutoNAT reachability, neither of which exists in
// private-IP Docker NAT testbeds. The manual flow is spec-identical
// (CONNECT/CONNECT/SYNC + RTT/2 wait + simultaneous dials with
// network.WithSimultaneousConnect roles).
//
// Roles via env (see run-peer.sh for the NAT route setup):
//   - listener: reserves a relay slot, publishes its peer ID, drives DCUtR
//     as spec-B (initiates on inbound relayed connections), waits.
//   - dialer: dials the listener through the relay circuit, responds to
//     DCUtR as spec-A, waits for a direct connection, pings, prints the
//     latency block the harness parses.

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	relayv2 "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
	"github.com/libp2p/go-libp2p/p2p/protocol/holepunch"
	holepunchpb "github.com/libp2p/go-libp2p/p2p/protocol/holepunch/pb"
	idpb "github.com/libp2p/go-libp2p/p2p/protocol/identify/pb"
	"github.com/libp2p/go-libp2p/p2p/protocol/ping"
	"github.com/libp2p/go-msgio/pbio"
	ma "github.com/multiformats/go-multiaddr"

	"github.com/redis/go-redis/v9"
)

const dialerBudget = 150 * time.Second
const maxMsgSize = 4 * 1024

func getEnv(name string) string {
	v := os.Getenv(name)
	if v == "" {
		fmt.Fprintf(os.Stderr, "Missing required environment variable: %s\n", name)
		os.Exit(1)
	}
	return v
}

func getContainerIP(redisAddr string) string {
	conn, err := net.Dial("udp", redisAddr)
	if err != nil {
		return "127.0.0.1"
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

func redisGet(ctx context.Context, r *redis.Client, key string) (string, error) {
	val, err := r.Get(ctx, key).Result()
	if errors.Is(err, redis.Nil) {
		return "", nil
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

func peerMultiaddr(h host.Host) string {
	for _, a := range h.Addrs() {
		return fmt.Sprintf("%s/p2p/%s", a.String(), h.ID().String())
	}
	return ""
}

// runRelayMode serves as a circuit relay v2 hop relay: listen on RELAY_IP,
// accept reservations with generous limits, publish the multiaddr, serve.
func runRelayMode() {
	redisAddr := getEnv("REDIS_ADDR")
	testKey := getEnv("TEST_KEY")
	relayIP := getEnv("RELAY_IP")

	ctx := context.Background()
	r := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer r.Close()

	listenAddr, _ := ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", relayIP))
	h, err := libp2p.New(libp2p.ListenAddrs(listenAddr))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create relay host: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	res := relayv2.DefaultResources()
	res.MaxReservations = 100
	res.MaxCircuits = 100
	relaySvc, err := relayv2.New(h, relayv2.WithResources(res))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start relay service: %v\n", err)
		os.Exit(1)
	}
	defer relaySvc.Close()

	relayMA := peerMultiaddr(h)
	if err := r.Set(ctx, fmt.Sprintf("%s_relay_multiaddr", testKey), relayMA, 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to publish relay multiaddr: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("Relay ready at %s\n", relayMA)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func hasDirectConn(h host.Host, p peer.ID) bool {
	for _, c := range h.Network().ConnsToPeer(p) {
		if !c.Stat().Limited {
			return true
		}
	}
	return false
}

// tcpIPPort splits a multiaddr into (family, ip, tcpport); ok=false if not TCP/IP.
func tcpIPPort(a ma.Multiaddr) (family int, ip string, port string, ok bool) {
	for _, f := range []struct {
		fam  int
		code int
	}{{4, ma.P_IP4}, {6, ma.P_IP6}} {
		v, err := a.ValueForProtocol(f.code)
		if err == nil && v != "" {
			family, ip = f.fam, v
			break
		}
	}
	if ip == "" {
		return 0, "", "", false
	}
	p, err := a.ValueForProtocol(ma.P_TCP)
	if err != nil || p == "" {
		return 0, "", "", false
	}
	return family, ip, p, true
}

// ─── Manual DCUtR ─────────────────────────────────────────────────────────────

type dcutrSvc struct {
	h        host.Host
	obsAddrs [][]byte // our advertised addresses (binary multiaddrs, no /p2p)

	mu         sync.Mutex
	inProgress map[peer.ID]bool
	attempts   map[peer.ID]int
}

func newDcutrSvc(h host.Host, obsAddrs [][]byte) *dcutrSvc {
	d := &dcutrSvc{h: h, obsAddrs: obsAddrs, inProgress: map[peer.ID]bool{}, attempts: map[peer.ID]int{}}
	h.SetStreamHandler(holepunch.Protocol, d.handleStream)
	return d
}

func decodeAddrs(raw [][]byte) []ma.Multiaddr {
	var out []ma.Multiaddr
	for _, b := range raw {
		a, err := ma.NewMultiaddrBytes(b)
		if err != nil {
			continue
		}
		if _, err := a.ValueForProtocol(ma.P_CIRCUIT); err == nil {
			continue
		}
		out = append(out, a)
	}
	return out
}

func (d *dcutrSvc) writeMsg(s network.Stream, msg *holepunchpb.HolePunch) error {
	s.SetDeadline(time.Now().Add(30 * time.Second))
	w := pbio.NewDelimitedWriter(s)
	return w.WriteMsg(msg)
}

func (d *dcutrSvc) readMsg(s network.Stream) (*holepunchpb.HolePunch, error) {
	s.SetDeadline(time.Now().Add(30 * time.Second))
	rd := pbio.NewDelimitedReader(s, maxMsgSize)
	msg := &holepunchpb.HolePunch{}
	if err := rd.ReadMsg(msg); err != nil {
		return nil, err
	}
	return msg, nil
}

// handleStream is the spec-A (responder) side: CONNECT in, CONNECT out,
// SYNC in, then dial immediately as client.
func (d *dcutrSvc) handleStream(s network.Stream) {
	defer s.Close()
	remote := s.Conn().RemotePeer()
	msg, err := d.readMsg(s)
	if err != nil || msg.GetType() != holepunchpb.HolePunch_CONNECT {
		return
	}
	peerAddrs := decodeAddrs(msg.GetObsAddrs())
	if err := d.writeMsg(s, &holepunchpb.HolePunch{
		Type:     holepunchpb.HolePunch_CONNECT.Enum(),
		ObsAddrs: d.obsAddrs,
	}); err != nil {
		return
	}
	syncMsg, err := d.readMsg(s)
	if err != nil || syncMsg.GetType() != holepunchpb.HolePunch_SYNC {
		return
	}
	d.punch(remote, peerAddrs, true)
}

// initiate is the spec-B side: open stream, CONNECT/CONNECT/SYNC, wait
// RTT/2, then dial as server. Serialized per peer: strict implementations
// reject concurrent inbound DCUtR sessions.
func (d *dcutrSvc) initiate(p peer.ID) {
	d.mu.Lock()
	if d.inProgress[p] || d.attempts[p] >= 3 {
		d.mu.Unlock()
		return
	}
	d.inProgress[p] = true
	d.attempts[p]++
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.inProgress, p)
		d.mu.Unlock()
	}()

	if hasDirectConn(d.h, p) {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	lctx := network.WithAllowLimitedConn(ctx, "dcutr")
	s, err := d.h.NewStream(lctx, p, holepunch.Protocol)
	if err != nil {
		return
	}
	defer s.Close()

	sentAt := time.Now()
	if err := d.writeMsg(s, &holepunchpb.HolePunch{
		Type:     holepunchpb.HolePunch_CONNECT.Enum(),
		ObsAddrs: d.obsAddrs,
	}); err != nil {
		return
	}
	resp, err := d.readMsg(s)
	if err != nil || resp.GetType() != holepunchpb.HolePunch_CONNECT {
		return
	}
	rtt := time.Since(sentAt)
	peerAddrs := decodeAddrs(resp.GetObsAddrs())
	if err := d.writeMsg(s, &holepunchpb.HolePunch{Type: holepunchpb.HolePunch_SYNC.Enum()}); err != nil {
		return
	}
	delay := rtt / 2
	if delay > 2*time.Second {
		delay = 2 * time.Second
	}
	select {
	case <-time.After(delay):
	case <-ctx.Done():
		return
	}
	d.punch(p, peerAddrs, false)
}

// punch dials every address (up to 3 rounds) with spec Noise roles.
func (d *dcutrSvc) punch(p peer.ID, addrs []ma.Multiaddr, isClient bool) {
	if len(addrs) == 0 {
		return
	}
	for round := 0; round < 3; round++ {
		for _, a := range addrs {
			go func(addr ma.Multiaddr) {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				hpCtx := network.WithSimultaneousConnect(ctx, isClient, "hp-test")
				hpCtx = network.WithForceDirectDial(hpCtx, "hp-test")
				_ = d.h.Connect(hpCtx, peer.AddrInfo{ID: p, Addrs: []ma.Multiaddr{addr}})
			}(a)
		}
		time.Sleep(500 * time.Millisecond)
		if hasDirectConn(d.h, p) {
			return
		}
		time.Sleep(2 * time.Second)
	}
}

// notifiee drives spec-B initiation on inbound relayed connections.
type dcutrNotifiee struct{ d *dcutrSvc }

func (n *dcutrNotifiee) Listen(network.Network, ma.Multiaddr)      {}
func (n *dcutrNotifiee) ListenClose(network.Network, ma.Multiaddr) {}
func (n *dcutrNotifiee) Disconnected(network.Network, network.Conn) {}
func (n *dcutrNotifiee) Connected(_ network.Network, c network.Conn) {
	if c.Stat().Direction != network.DirInbound {
		return
	}
	if !strings.Contains(c.RemoteMultiaddr().String(), "p2p-circuit") {
		return
	}
	go n.d.initiate(c.RemotePeer())
}

// fetchObservedAddr asks the relay (via identify) how it observes us.
// This is our NAT external address; reservation vouchers only carry the
// relay's own addresses and must not be used for this.
func fetchObservedAddr(ctx context.Context, h host.Host, relayID peer.ID) ma.Multiaddr {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	s, err := h.NewStream(ctx, relayID, "/ipfs/id/1.0.0")
	if err != nil {
		fmt.Printf("identify fetch: open stream failed: %v\n", err)
		return nil
	}
	defer s.Close()
	s.SetDeadline(time.Now().Add(15 * time.Second))
	rd := pbio.NewDelimitedReader(s, 64*1024)
	for {
		msg := &idpb.Identify{}
		if err := rd.ReadMsg(msg); err != nil {
			return nil
		}
		if len(msg.ObservedAddr) == 0 {
			continue
		}
		obs, err := ma.NewMultiaddrBytes(msg.ObservedAddr)
		if err != nil {
			return nil
		}
		fmt.Printf("identify fetch: relay observes us as %s\n", obs.String())
		return obs
	}
}

// ourAdvertisedAddrs builds (WAN_IP:listen_port) predictions from our
// NAT external address, like the spec's predicted addresses.
func ourAdvertisedAddrs(h host.Host, observed ma.Multiaddr) [][]byte {
	type tpp struct {
		fam  int
		port string
	}
	var listenPorts []tpp
	for _, a := range h.Addrs() {
		if fam, _, port, ok := tcpIPPort(a); ok {
			listenPorts = append(listenPorts, tpp{fam, port})
		}
	}
	seen := map[string]bool{}
	var out [][]byte
	if fam, ip, _, ok := tcpIPPort(observed); ok {
		for _, lp := range listenPorts {
			if lp.fam != fam {
				continue
			}
			cand, err := ma.NewMultiaddr(fmt.Sprintf("/ip%d/%s/tcp/%s", fam, ip, lp.port))
			if err != nil {
				continue
			}
			if s := string(cand.Bytes()); !seen[s] {
				seen[s] = true
				out = append(out, cand.Bytes())
			}
		}
	}
	if len(out) == 0 {
		// No observed address (direct/LAN case): advertise listen addrs bare.
		for _, a := range h.Addrs() {
			b := a.Bytes()
			if s := string(b); !seen[s] {
				seen[s] = true
				out = append(out, b)
			}
		}
	}
	return out
}

func runListener(ctx context.Context, h host.Host, relayInfo *peer.AddrInfo, r *redis.Client, testKey string) {
	if err := h.Connect(ctx, *relayInfo); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to connect to relay: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("INF Connected to relay relayId=%s\n", relayInfo.ID.String())

	var rsvp *client.Reservation
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		resCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		var err error
		rsvp, err = client.Reserve(resCtx, h, *relayInfo)
		cancel()
		if err == nil {
			break
		}
		fmt.Printf("Reserve retry: %v\n", err)
		time.Sleep(2 * time.Second)
	}
	if rsvp == nil {
		fmt.Fprintln(os.Stderr, "Relay never accepted our reservation")
		os.Exit(1)
	}

	observed := fetchObservedAddr(ctx, h, relayInfo.ID)
	d := newDcutrSvc(h, ourAdvertisedAddrs(h, observed))
	h.Network().Notify(&dcutrNotifiee{d: d})

	listenerKey := fmt.Sprintf("%s_listener_peer_id", testKey)
	if err := r.Set(ctx, listenerKey, h.ID().String(), 0).Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to publish listener peer ID: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("INF Published listener peer id, waiting for hole punch... listenerId=%s\n", h.ID().String())

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh
}

func runDialer(ctx context.Context, h host.Host, relayInfo *peer.AddrInfo, r *redis.Client, testKey string) {
	fail := func(msg string) {
		fmt.Printf("error: %s\n", msg)
		os.Exit(1)
	}

	if err := h.Connect(ctx, *relayInfo); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to connect to relay: %v\n", err)
		os.Exit(1)
	}

	// The dialer also reserves: it needs vouched addresses for its own
	// CONNECT responses when the peer initiates DCUtR to us.
	var rsvp *client.Reservation
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		resCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
		var err error
		rsvp, err = client.Reserve(resCtx, h, *relayInfo)
		cancel()
		if err == nil {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if rsvp == nil {
		fail("Relay never accepted our reservation")
	}
	observed := fetchObservedAddr(ctx, h, relayInfo.ID)
	d := newDcutrSvc(h, ourAdvertisedAddrs(h, observed))
	h.Network().Notify(&dcutrNotifiee{d: d})

	listenerKey := fmt.Sprintf("%s_listener_peer_id", testKey)
	listenerIDStr := waitForKey(ctx, r, listenerKey, 60*time.Second)
	if listenerIDStr == "" {
		fail("Timeout waiting for listener peer id")
	}
	listenerID, err := peer.Decode(listenerIDStr)
	if err != nil {
		fail(fmt.Sprintf("Bad listener peer ID: %v", err))
	}

	relayBase := relayInfo.Addrs[0].String() + "/p2p/" + relayInfo.ID.String()
	circuitAddrStr := fmt.Sprintf("%s/p2p-circuit/p2p/%s", relayBase, listenerIDStr)
	circuitMA, err := ma.NewMultiaddr(circuitAddrStr)
	if err != nil {
		fail(fmt.Sprintf("Bad circuit address: %v", err))
	}
	fmt.Printf("INF Dialling listener through relay: %s\n", circuitAddrStr)

	hpStart := time.Now()
	target := peer.AddrInfo{ID: listenerID, Addrs: []ma.Multiaddr{circuitMA}}
	dialDeadline := time.Now().Add(60 * time.Second)
	dialed := false
	for time.Now().Before(dialDeadline) {
		dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := h.Connect(dialCtx, target)
		cancel()
		if err == nil {
			dialed = true
			break
		}
		fmt.Printf("Circuit dial retry: %v\n", err)
		time.Sleep(2 * time.Second)
	}
	if !dialed {
		fail("Relayed circuit to listener failed")
	}
	fmt.Println("INF Relayed circuit to listener established")

	directDeadline := time.Now().Add(120 * time.Second)
	for !hasDirectConn(h, listenerID) {
		if time.Now().After(directDeadline) {
			fail("No direct connection after DCUtR")
		}
		time.Sleep(1 * time.Second)
	}
	fmt.Println("INF DCUtR hole punch succeeded")
	dcutrElapsed := time.Since(hpStart)

	pingCtx, pingCancel := context.WithTimeout(ctx, 30*time.Second)
	defer pingCancel()
	res := <-ping.Ping(pingCtx, h, listenerID)
	if res.Error != nil {
		fail(fmt.Sprintf("Ping over direct connection failed: %v", res.Error))
	}
	pingRTTms := float64(res.RTT.Microseconds()) / 1000.0
	handshakeMs := float64(dcutrElapsed.Microseconds())/1000.0 + pingRTTms
	fmt.Printf("INF Ping over direct connection: %.2fms\n", pingRTTms)

	fmt.Println("latency:")
	fmt.Printf("  handshake_plus_one_rtt: %.2f\n", handshakeMs)
	fmt.Printf("  ping_rtt: %.2f\n", pingRTTms)
	fmt.Println("  unit: ms")
}

func main() {
	// Relay mode: the harness compose for relays sets RELAY_IP and no
	// IS_DIALER (see run-relay.sh).
	if os.Getenv("IS_DIALER") == "" && os.Getenv("RELAY_IP") != "" {
		runRelayMode()
		return
	}
	isDialer := os.Getenv("IS_DIALER") == "true"
	redisAddr := getEnv("REDIS_ADDR")
	testKey := getEnv("TEST_KEY")
	transport := os.Getenv("TRANSPORT")
	secure := os.Getenv("SECURE_CHANNEL")
	muxer := os.Getenv("MUXER")
	if transport != "" && transport != "tcp" || secure != "" && secure != "noise" || muxer != "" && muxer != "yamux" {
		fmt.Fprintf(os.Stderr, "Unsupported combo (only tcp/noise/yamux): %s/%s/%s\n", transport, secure, muxer)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), dialerBudget)
	defer cancel()

	r := redis.NewClient(&redis.Options{Addr: redisAddr})
	defer r.Close()

	bindIP := os.Getenv("LISTENER_IP")
	if isDialer {
		bindIP = os.Getenv("DIALER_IP")
	}
	if bindIP == "" {
		bindIP = getContainerIP(redisAddr)
	}
	listenAddr, _ := ma.NewMultiaddr(fmt.Sprintf("/ip4/%s/tcp/0", bindIP))
	// NOTE: no EnableHolePunching — the stock service requires public
	// observed addresses + AutoNAT reachability, unavailable in private-IP
	// testbeds. DCUtR here is manual (spec roles + simultaneous dials).
	h, err := libp2p.New(libp2p.ListenAddrs(listenAddr))
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create host: %v\n", err)
		os.Exit(1)
	}
	defer h.Close()

	if isDialer {
		fmt.Printf("INF Dialer %s started\n", h.ID().String())
	} else {
		fmt.Printf("INF Listener %s started\n", h.ID().String())
	}

	relayAddr := waitForKey(ctx, r, fmt.Sprintf("%s_relay_multiaddr", testKey), 60*time.Second)
	if relayAddr == "" {
		fmt.Println("error: Timeout waiting for relay multiaddr")
		os.Exit(1)
	}
	relayInfo := mustAddrInfo(relayAddr)

	if isDialer {
		runDialer(ctx, h, relayInfo, r, testKey)
	} else {
		runListener(ctx, h, relayInfo, r, testKey)
	}
}
