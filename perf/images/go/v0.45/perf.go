package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"time"

	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
)

const perfProtocol = protocol.ID("/perf/1.0.0")
const blockSize = 64 * 1024

var sendBlock [blockSize]byte

func handlePerfStream(stream network.Stream) {
	defer stream.Close()
	var header [8]byte
	if _, err := io.ReadFull(stream, header[:]); err != nil {
		log.Printf("read perf header: %v", err)
		stream.Reset()
		return
	}

	if _, err := io.Copy(io.Discard, stream); err != nil {
		log.Printf("read perf upload: %v", err)
		stream.Reset()
		return
	}
	if err := writeBytes(stream, binary.BigEndian.Uint64(header[:])); err != nil {
		log.Printf("write perf response: %v", err)
		stream.Reset()
		return
	}
	if err := stream.CloseWrite(); err != nil {
		log.Printf("close perf response: %v", err)
		stream.Reset()
	}
}

func runPerfIteration(ctx context.Context, h host.Host, p peer.ID, upload, download uint64) (time.Duration, error) {
	start := time.Now()
	stream, err := h.NewStream(ctx, p, perfProtocol)
	if err != nil {
		return 0, fmt.Errorf("open perf stream: %w", err)
	}
	defer stream.Close()
	if deadline, ok := ctx.Deadline(); ok {
		if err := stream.SetDeadline(deadline); err != nil {
			return 0, fmt.Errorf("set perf deadline: %w", err)
		}
	}

	var header [8]byte
	binary.BigEndian.PutUint64(header[:], download)
	if n, err := stream.Write(header[:]); err != nil {
		return 0, fmt.Errorf("write perf header: %w", err)
	} else if n != len(header) {
		return 0, fmt.Errorf("write perf header: %w", io.ErrShortWrite)
	}
	if err := writeBytes(stream, upload); err != nil {
		return 0, fmt.Errorf("write perf upload: %w", err)
	}
	if err := stream.CloseWrite(); err != nil {
		return 0, fmt.Errorf("close perf upload: %w", err)
	}

	received, err := io.Copy(io.Discard, stream)
	if err != nil {
		return 0, fmt.Errorf("read perf response: %w", err)
	}
	if uint64(received) != download {
		return 0, fmt.Errorf("perf response has %d bytes, want %d", received, download)
	}
	return time.Since(start), nil
}

func writeBytes(w io.Writer, count uint64) error {
	for count > 0 {
		chunkSize := uint64(blockSize)
		if count < chunkSize {
			chunkSize = count
		}
		n, err := w.Write(sendBlock[:chunkSize])
		if err != nil {
			return err
		}
		if n != int(chunkSize) {
			return io.ErrShortWrite
		}
		count -= chunkSize
	}
	return nil
}
