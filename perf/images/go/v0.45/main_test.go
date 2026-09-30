package main

import (
	"context"
	"encoding/binary"
	"io"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
)

func TestSelectListenerAddrSkipsLoopback(t *testing.T) {
	addrs := []multiaddr.Multiaddr{
		multiaddr.StringCast("/ip4/127.0.0.1/udp/4001/quic-v1"),
		multiaddr.StringCast("/ip4/0.0.0.0/udp/4001/quic-v1"),
		multiaddr.StringCast("/ip4/172.18.0.2/udp/4001/quic-v1"),
	}
	got, err := selectListenerAddr(addrs)
	if err != nil {
		t.Fatal(err)
	}
	if want := addrs[2].String(); got != want {
		t.Fatalf("advertised %q, want %q", got, want)
	}
}

func TestSelectListenerAddrRejectsLoopbackOnly(t *testing.T) {
	addrs := []multiaddr.Multiaddr{multiaddr.StringCast("/ip4/127.0.0.1/udp/4001/quic-v1")}
	if got, err := selectListenerAddr(addrs); err == nil {
		t.Fatalf("advertised unreachable address %q", got)
	}
}

func connectedHosts(t *testing.T) (host.Host, host.Host) {
	t.Helper()
	listener, err := libp2p.New(libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })

	dialer, err := libp2p.New(libp2p.NoListenAddrs)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dialer.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := dialer.Connect(ctx, peer.AddrInfo{ID: listener.ID(), Addrs: listener.Addrs()}); err != nil {
		t.Fatal(err)
	}
	return listener, dialer
}

func TestPerfTransfer(t *testing.T) {
	listener, dialer := connectedHosts(t)
	listener.SetStreamHandler(perfProtocol, handlePerfStream)

	for _, tc := range []struct {
		name     string
		upload   uint64
		download uint64
	}{
		{"empty", 0, 0},
		{"single byte", 1, 1},
		{"multi block", 65537, 65539},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if _, err := runPerfIteration(ctx, dialer, listener.ID(), tc.upload, tc.download); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPerfShortResponseFails(t *testing.T) {
	listener, dialer := connectedHosts(t)
	listener.SetStreamHandler(perfProtocol, func(stream network.Stream) {
		defer stream.Close()
		var header [8]byte
		if _, err := io.ReadFull(stream, header[:]); err != nil {
			t.Errorf("read request: %v", err)
			return
		}
		if got := binary.BigEndian.Uint64(header[:]); got != 2 {
			t.Errorf("requested download = %d, want 2", got)
			return
		}
		if _, err := io.Copy(io.Discard, stream); err != nil {
			t.Errorf("drain upload: %v", err)
			return
		}
		if _, err := stream.Write([]byte{1}); err != nil {
			t.Errorf("write response: %v", err)
			return
		}
		stream.CloseWrite()
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := runPerfIteration(ctx, dialer, listener.ID(), 1, 2); err == nil {
		t.Fatal("short response was reported as a successful measurement")
	}
}

func TestPerfWithoutHandlerFails(t *testing.T) {
	listener, dialer := connectedHosts(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := runPerfIteration(ctx, dialer, listener.ID(), 1, 1); err == nil {
		t.Fatal("missing /perf/1.0.0 handler was reported as a successful measurement")
	}
	if _, err := runMeasurement(ctx, dialer, listener.ID(), 1024, 0, 1); err == nil {
		t.Fatal("missing handler produced benchmark statistics")
	}
}

func TestPerfRejectsInvalidMeasurement(t *testing.T) {
	for _, tc := range []struct {
		upload, download int64
		iterations       int
	}{
		{-1, 0, 1},
		{0, -1, 1},
		{0, 0, 0},
	} {
		if _, err := runMeasurement(context.Background(), nil, "", tc.upload, tc.download, tc.iterations); err == nil {
			t.Errorf("accepted upload=%d download=%d iterations=%d", tc.upload, tc.download, tc.iterations)
		}
	}
}

func TestPerfRejectsShortHeader(t *testing.T) {
	listener, dialer := connectedHosts(t)
	listener.SetStreamHandler(perfProtocol, handlePerfStream)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stream, err := dialer.NewStream(ctx, listener.ID(), perfProtocol)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if _, err := stream.Write([]byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	if err := stream.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	var response [1]byte
	if _, err := stream.Read(response[:]); err == nil {
		t.Fatal("short request header was accepted")
	}
}
