#!/usr/bin/env node
/**
 * hole-punch/images/js/v3.x/index.js
 *
 * JS-libp2p v3.x implementation of the unified-testing hole-punch suite.
 * Handles three modes via environment variables:
 *
 *   IS_RELAY=true          → Circuit-relay server (WAN)
 *   IS_DIALER=true         → Peer behind NAT that initiates the connection
 *   IS_DIALER=false        → Peer behind NAT that waits for the connection
 *
 * Protocol support (TCP only for initial implementation; extend as needed).
 *
 * IMPORTANT: All diagnostic output goes to stderr.
 *            Results YAML goes to stdout (dialer only).
 */

import { createLibp2p } from 'libp2p'
import { tcp } from '@libp2p/tcp'
import { noise } from '@libp2p/noise'
import { yamux } from '@libp2p/yamux'
import { circuitRelayServer } from '@libp2p/circuit-relay-v2'
import { circuitRelayTransport } from '@libp2p/circuit-relay-v2'
import { dcutr } from '@libp2p/dcutr'
import { identify } from '@libp2p/identify'
import { multiaddr } from '@multiformats/multiaddr'
import Redis from 'ioredis'

// ── Environment variables ─────────────────────────────────────────────────────
const IS_RELAY    = process.env.IS_RELAY   === 'true'
const IS_DIALER   = process.env.IS_DIALER  === 'true'
const REDIS_ADDR  = process.env.REDIS_ADDR || 'hole-punch-redis:6379'
const TEST_KEY    = process.env.TEST_KEY   || 'testkey01'
const TRANSPORT   = process.env.TRANSPORT  || 'tcp'
const RELAY_IP    = process.env.RELAY_IP   || '0.0.0.0'
const PEER_IP     = process.env.PEER_IP    || '0.0.0.0'
const DEBUG       = process.env.DEBUG      === 'true'

function dbg (...args) { if (DEBUG) console.error('[debug]', ...args) }
function log (...args) { console.error(...args) }

// ── Redis helpers ──────────────────────────────────────────────────────────────
function redisClient () {
  const [host, port] = REDIS_ADDR.split(':')
  return new Redis({ host, port: parseInt(port, 10), lazyConnect: true })
}

async function redisWait (client, key, pollMs = 500, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const val = await client.get(key)
    if (val) return val
    await new Promise(r => setTimeout(r, pollMs))
  }
  throw new Error(`Timeout waiting for Redis key: ${key}`)
}

// ── Transport factory ─────────────────────────────────────────────────────────
function makeTransports (includeCircuitRelay) {
  const transports = [tcp()]
  if (includeCircuitRelay) transports.push(circuitRelayTransport({ discoverRelays: 1 }))
  return transports
}

// ─────────────────────────────────────────────────────────────────────────────
// RELAY
// ─────────────────────────────────────────────────────────────────────────────
async function runRelay () {
  log('Starting relay server...')

  const node = await createLibp2p({
    addresses: {
      listen: [`/ip4/${RELAY_IP}/tcp/4001`]
    },
    transports: [tcp()],
    connectionEncryption: [noise()],
    streamMuxers: [yamux()],
    services: {
      identify: identify(),
      relay: circuitRelayServer({ reservations: { maxReservations: 128 } })
    }
  })

  await node.start()

  const ma = `/ip4/${RELAY_IP}/tcp/4001/p2p/${node.peerId.toString()}`
  log(`Relay multiaddr: ${ma}`)

  const redis = redisClient()
  await redis.connect()
  await redis.set(`${TEST_KEY}_relay_multiaddr`, ma)
  await redis.quit()
  log(`Published relay multiaddr to Redis key: ${TEST_KEY}_relay_multiaddr`)

  // Keep running until Docker stops us
  await new Promise(() => {})
}

// ─────────────────────────────────────────────────────────────────────────────
// PEER (dialer and listener share the same node creation logic)
// ─────────────────────────────────────────────────────────────────────────────
async function createPeerNode (listenAddr) {
  return createLibp2p({
    addresses: {
      listen: [listenAddr, '/p2p-circuit']
    },
    transports: makeTransports(true),
    connectionEncryption: [noise()],
    streamMuxers: [yamux()],
    services: {
      identify: identify(),
      dcutr: dcutr()
    }
  })
}

// ─────────────────────────────────────────────────────────────────────────────
// LISTENER
// ─────────────────────────────────────────────────────────────────────────────
async function runListener () {
  log('Starting listener (behind NAT)...')

  const node = await createPeerNode(`/ip4/${PEER_IP}/tcp/4001`)
  await node.start()

  const myPeerId = node.peerId.toString()
  log(`Listener peer ID: ${myPeerId}`)

  const redis = redisClient()
  await redis.connect()

  // Publish our peer ID so the dialer can find us
  await redis.set(`${TEST_KEY}_listener_peer_id`, myPeerId)
  log(`Published peer ID to Redis key: ${TEST_KEY}_listener_peer_id`)

  // Wait for relay multiaddr
  log('Waiting for relay multiaddr from Redis...')
  const relayMa = await redisWait(redis, `${TEST_KEY}_relay_multiaddr`)
  await redis.quit()
  log(`Got relay multiaddr: ${relayMa}`)

  // Connect to relay to register our reservation
  log('Connecting to relay...')
  await node.dial(multiaddr(relayMa))
  log('Connected to relay — listening for DCUtR...')

  // Keep running until Docker stops us
  await new Promise(() => {})
}

// ─────────────────────────────────────────────────────────────────────────────
// DIALER
// ─────────────────────────────────────────────────────────────────────────────
async function runDialer () {
  log('Starting dialer (behind NAT)...')

  const node = await createPeerNode(`/ip4/${PEER_IP}/tcp/4001`)
  await node.start()

  log(`Dialer peer ID: ${node.peerId.toString()}`)

  const redis = redisClient()
  await redis.connect()

  // Wait for relay multiaddr
  log('Waiting for relay multiaddr from Redis...')
  const relayMa = await redisWait(redis, `${TEST_KEY}_relay_multiaddr`)
  log(`Got relay multiaddr: ${relayMa}`)

  // Wait for listener peer ID
  log('Waiting for listener peer ID from Redis...')
  const listenerPeerId = await redisWait(redis, `${TEST_KEY}_listener_peer_id`)
  await redis.quit()
  log(`Got listener peer ID: ${listenerPeerId}`)

  // Connect to relay
  log('Connecting to relay...')
  await node.dial(multiaddr(relayMa))
  log('Connected to relay')

  // Build the relayed address to the listener
  const relayBase = relayMa  // /ip4/.../tcp/4001/p2p/<relay-peer-id>
  const relayedAddr = `${relayBase}/p2p-circuit/p2p/${listenerPeerId}`
  log(`Dialing listener via relay: ${relayedAddr}`)

  // Start timer — DCUtR begins when we dial the listener through the relay
  const t0 = Date.now()

  const conn = await node.dial(multiaddr(relayedAddr))
  dbg(`Initial (relayed) connection established: ${conn.remoteAddr}`)

  // Wait for DCUtR to establish a direct connection
  // The DCUtR service upgrades relay connections automatically; we poll until
  // the connection is no longer going through a circuit relay.
  const DCUTR_TIMEOUT_MS = 30_000
  const deadline = Date.now() + DCUTR_TIMEOUT_MS
  let directConn = null

  while (Date.now() < deadline) {
    const conns = node.getConnections(conn.remotePeer)
    directConn = conns.find(c => !c.remoteAddr.toString().includes('p2p-circuit'))
    if (directConn) break
    await new Promise(r => setTimeout(r, 200))
  }

  const handshakeTime = Date.now() - t0

  if (!directConn) {
    console.error(`DCUtR failed — no direct connection after ${DCUTR_TIMEOUT_MS} ms`)
    process.exit(1)
  }

  log(`Direct connection established via DCUtR in ${handshakeTime} ms`)
  log(`Direct address: ${directConn.remoteAddr}`)

  // Emit YAML results to stdout
  console.log('# Measurements from dialer')
  console.log(`handshakeTime: ${handshakeTime}`)
  console.log('unit: ms')

  await node.stop()
}

// ── Entry point ───────────────────────────────────────────────────────────────
if (IS_RELAY) {
  runRelay().catch(err => { console.error('Relay error:', err); process.exit(1) })
} else if (IS_DIALER) {
  runDialer().catch(err => { console.error('Dialer error:', err); process.exit(1) })
} else {
  runListener().catch(err => { console.error('Listener error:', err); process.exit(1) })
}
