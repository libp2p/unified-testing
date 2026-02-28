#!/usr/bin/env node

import { createLibp2p } from 'libp2p'
import { tcp } from '@libp2p/tcp'
import { noise } from '@libp2p/noise'
import { yamux } from '@libp2p/yamux'
import { perf } from '@libp2p/perf'
import { multiaddr } from '@multiformats/multiaddr'
import Redis from 'ioredis'
import os from 'os'

// ── Environment variables ─────────────────────────────────────────────────────
const IS_DIALER        = process.env.IS_DIALER === 'true'
const REDIS_ADDR       = process.env.REDIS_ADDR       || 'perf-redis:6379'
const TEST_KEY         = process.env.TEST_KEY         || 'testkey01'
const TRANSPORT        = process.env.TRANSPORT        || 'tcp'
const LISTENER_IP      = process.env.LISTENER_IP      || '0.0.0.0'
const UPLOAD_BYTES     = parseInt(process.env.UPLOAD_BYTES     || '1073741824', 10)
const DOWNLOAD_BYTES   = parseInt(process.env.DOWNLOAD_BYTES   || '1073741824', 10)
const UPLOAD_ITERS     = parseInt(process.env.UPLOAD_ITERATIONS    || '10', 10)
const DOWNLOAD_ITERS   = parseInt(process.env.DOWNLOAD_ITERATIONS  || '10', 10)
const LATENCY_ITERS    = parseInt(process.env.LATENCY_ITERATIONS   || '100', 10)
const DEBUG            = process.env.DEBUG === 'true'

function dbg(...args) { if (DEBUG) console.error('[debug]', ...args) }

// ── Redis helpers ──────────────────────────────────────────────────────────────
function redisClient() {
  const [host, port] = REDIS_ADDR.split(':')
  return new Redis({ host, port: parseInt(port, 10), lazyConnect: true })
}

async function redisWait(client, key, pollMs = 500, timeoutMs = 120_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const val = await client.get(key)
    if (val) return val
    await new Promise(r => setTimeout(r, pollMs))
  }
  throw new Error(`Timeout waiting for Redis key: ${key}`)
}

// ── Non-localhost IP detection ────────────────────────────────────────────────
function localNonLoopbackIP() {
  for (const iface of Object.values(os.networkInterfaces()).flat()) {
    if (!iface.internal && iface.family === 'IPv4') return iface.address
  }
  return '0.0.0.0'
}

// ── Listener (server) ────────────────────────────────────────────────────────
async function runListener() {
  console.error('Starting perf listener...')

  const listenAddr = `/ip4/${LISTENER_IP}/tcp/4001`
  const node = await createLibp2p({
    addresses: { listen: [listenAddr] },
    transports: [tcp()],
    connectionEncryption: [noise()],
    streamMuxers: [yamux()],
    services: { perf: perf() }
  })

  await node.start()

  // Determine the publicly routable multiaddr
  const ip = localNonLoopbackIP()
  const ma = `/ip4/${ip}/tcp/4001/p2p/${node.peerId.toString()}`
  console.error(`Listener address: ${ma}`)

  // Publish to Redis so the dialer can find us
  const redis = redisClient()
  await redis.connect()
  await redis.set(`${TEST_KEY}_listener_multiaddr`, ma)
  await redis.quit()
  console.error(`Published multiaddr to Redis key: ${TEST_KEY}_listener_multiaddr`)

  // Keep running until Docker stops us
  await new Promise(() => {})
}

// ── Dialer (client) ──────────────────────────────────────────────────────────
async function runDialer() {
  console.error('Starting perf dialer...')
  dbg(`Upload: ${UPLOAD_BYTES} B × ${UPLOAD_ITERS}`)
  dbg(`Download: ${DOWNLOAD_BYTES} B × ${DOWNLOAD_ITERS}`)
  dbg(`Latency: ${LATENCY_ITERS} iterations`)

  const node = await createLibp2p({
    transports: [tcp()],
    connectionEncryption: [noise()],
    streamMuxers: [yamux()],
    services: { perf: perf() }
  })

  await node.start()

  // Wait for listener multiaddr from Redis
  const redis = redisClient()
  await redis.connect()
  console.error('Waiting for listener multiaddr from Redis...')
  const listenerMa = await redisWait(redis, `${TEST_KEY}_listener_multiaddr`)
  await redis.quit()
  console.error(`Got listener multiaddr: ${listenerMa}`)

  // Dial the listener
  const conn = await node.dial(multiaddr(listenerMa))
  console.error('Connected to listener')

  const perfService = node.services.perf

  // Upload test
  console.error(`Running upload test (${UPLOAD_ITERS} iterations, ${UPLOAD_BYTES} bytes each)...`)
  const uploadResults = []
  for (let i = 0; i < UPLOAD_ITERS; i++) {
    for await (const result of perfService.measurePerformance(conn.remotePeer, UPLOAD_BYTES, 0)) {
      uploadResults.push(result.uploadThroughput / 1_000_000_000) // bps → Gbps
    }
  }

  // Download test
  console.error(`Running download test (${DOWNLOAD_ITERS} iterations, ${DOWNLOAD_BYTES} bytes each)...`)
  const downloadResults = []
  for (let i = 0; i < DOWNLOAD_ITERS; i++) {
    for await (const result of perfService.measurePerformance(conn.remotePeer, 0, DOWNLOAD_BYTES)) {
      downloadResults.push(result.downloadThroughput / 1_000_000_000) // bps → Gbps
    }
  }

  // Latency test (1 byte up + 1 byte down = round-trip)
  console.error(`Running latency test (${LATENCY_ITERS} iterations)...`)
  const latencyResults = []
  for (let i = 0; i < LATENCY_ITERS; i++) {
    for await (const result of perfService.measurePerformance(conn.remotePeer, 1, 1)) {
      // latency = time to transfer 2 bytes; use upload time as RTT proxy
      latencyResults.push(result.timeSeconds * 1000) // s → ms
    }
  }

  await node.stop()

  // Output YAML results
  const uploadStats   = calculateStats(uploadResults)
  const downloadStats = calculateStats(downloadResults)
  const latencyStats  = calculateStats(latencyResults)

  console.log('# Measurements from dialer')
  printStats('upload',   uploadStats,   UPLOAD_ITERS,   2, 'Gbps')
  console.log()
  printStats('download', downloadStats, DOWNLOAD_ITERS, 2, 'Gbps')
  console.log()
  printStats('latency',  latencyStats,  LATENCY_ITERS,  3, 'ms')

  console.error('All measurements complete!')
}

// ── Stats helpers ─────────────────────────────────────────────────────────────
function calculateStats(values) {
  values.sort((a, b) => a - b)
  const n = values.length
  const min = values[0]
  const max = values[n - 1]
  const q1     = percentile(values, 25.0)
  const median = percentile(values, 50.0)
  const q3     = percentile(values, 75.0)
  const iqr    = q3 - q1
  const lowerFence = q1 - 1.5 * iqr
  const upperFence = q3 + 1.5 * iqr
  const outliers = values.filter(v => v < lowerFence || v > upperFence)
  return { min, q1, median, q3, max, outliers }
}

function percentile(sortedValues, p) {
  const n = sortedValues.length
  const index = (p / 100.0) * (n - 1)
  const lower = Math.floor(index)
  const upper = Math.ceil(index)
  if (lower === upper) return sortedValues[lower]
  const weight = index - lower
  return sortedValues[lower] * (1.0 - weight) + sortedValues[upper] * weight
}

function printStats(key, stats, iters, decimals, unit) {
  console.log(`${key}:`)
  console.log(`  iterations: ${iters}`)
  console.log(`  min: ${stats.min.toFixed(decimals)}`)
  console.log(`  q1: ${stats.q1.toFixed(decimals)}`)
  console.log(`  median: ${stats.median.toFixed(decimals)}`)
  console.log(`  q3: ${stats.q3.toFixed(decimals)}`)
  console.log(`  max: ${stats.max.toFixed(decimals)}`)
  if (stats.outliers.length === 0) {
    console.log('  outliers: []')
  } else {
    console.log(`  outliers: [${stats.outliers.map(v => v.toFixed(decimals)).join(', ')}]`)
  }
  console.log(`  unit: ${unit}`)
}

// ── Entry point ────────────────────────────────────────────────────────────────
if (IS_DIALER) {
  runDialer().catch(err => {
    console.error('Dialer error:', err)
    process.exit(1)
  })
} else {
  runListener().catch(err => {
    console.error('Listener error:', err)
    process.exit(1)
  })
}
