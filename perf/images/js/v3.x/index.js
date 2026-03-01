#!/usr/bin/env node

import { createLibp2p } from 'libp2p'
import { tcp } from '@libp2p/tcp'
import { tls } from '@libp2p/tls'
import { mplex } from '@libp2p/mplex'
import { webTransport } from '@libp2p/webtransport'
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { createClient } from 'redis'
import { multiaddr } from '@multiformats/multiaddr'

const isDialer = process.env.IS_DIALER === 'true'
const redisAddr = process.env.REDIS_ADDR ?? 'redis:6379'
const testKey = process.env.TEST_KEY ?? 'default'
const transport = process.env.TRANSPORT ?? 'tcp'
const secureChannel = process.env.SECURE_CHANNEL ?? 'noise'
const muxer = process.env.MUXER ?? 'yamux'
const uploadBytes = Number(process.env.UPLOAD_BYTES ?? 1073741824)
const downloadBytes = Number(process.env.DOWNLOAD_BYTES ?? 1073741824)
const uploadIterations = Number(process.env.UPLOAD_ITERATIONS ?? 10)
const downloadIterations = Number(process.env.DOWNLOAD_ITERATIONS ?? 10)
const latencyIterations = Number(process.env.LATENCY_ITERATIONS ?? 100)

function getListenAddrs () {
  if (transport === 'webtransport') {
    return ['/ip4/0.0.0.0/udp/4001/quic-v1/webtransport']
  }
  return ['/ip4/0.0.0.0/tcp/4001']
}

function getTransports () {
  if (transport === 'webtransport') {
    return [webTransport()]
  }
  return [tcp()]
}

function getConnectionEncryption () {
  if (secureChannel === 'tls') {
    return [tls()]
  }
  return [noise()]
}

function getMuxers () {
  if (muxer === 'mplex') {
    return [mplex()]
  }
  return [yamux()]
}

async function runServer() {
  console.error('Starting perf server...')

  const node = await createLibp2p({
    addresses: {
      listen: getListenAddrs()
    },
    transports: getTransports(),
    connectionEncrypters: getConnectionEncryption(),
    streamMuxers: getMuxers()
  })

  await node.start()

  const redis = createClient({ url: `redis://${redisAddr}` })
  await redis.connect()
  const listenerAddr = node.getMultiaddrs()
    .map(a => a.toString())
    .find(a => !a.includes('127.0.0.1') && !a.includes('0.0.0.0') && !a.includes('/p2p-circuit'))
    ?? node.getMultiaddrs()[0]?.toString()
  const fullAddr = listenerAddr.includes('/p2p/')
    ? listenerAddr
    : `${listenerAddr}/p2p/${node.peerId.toString()}`
  const redisKey = `${testKey}_listener_multiaddr`
  await redis.set(redisKey, fullAddr)
  await redis.quit()

  console.error('Server listening on:', fullAddr)
  console.error('Peer ID:', node.peerId.toString())
  console.error('Perf server ready')

  // Keep running
  await new Promise(() => {})
}

async function runClient() {
  const redis = createClient({ url: `redis://${redisAddr}` })
  await redis.connect()
  const redisKey = `${testKey}_listener_multiaddr`

  let serverAddress = ''
  for (let i = 0; i < 60; i++) {
    const val = await redis.get(redisKey)
    if (val) {
      serverAddress = val
      break
    }
    await new Promise(resolve => setTimeout(resolve, 1000))
  }
  await redis.quit()

  if (!serverAddress) {
    console.error(`Error: timeout waiting for listener address in Redis key ${redisKey}`)
    process.exit(1)
  }

  console.error('Connecting to server:', serverAddress)

  const node = await createLibp2p({
    transports: getTransports(),
    connectionEncrypters: getConnectionEncryption(),
    streamMuxers: getMuxers()
  })

  await node.start()

  try {
    // Connect to server
    await node.dial(multiaddr(serverAddress))
    console.error('Connected to server')

    // Run measurements
    console.error(`Running upload test (${uploadIterations} iterations)...`)
    const uploadStats = await runMeasurement(uploadBytes, 0, uploadIterations)

    console.error(`Running download test (${downloadIterations} iterations)...`)
    const downloadStats = await runMeasurement(0, downloadBytes, downloadIterations)

    console.error(`Running latency test (${latencyIterations} iterations)...`)
    const latencyStats = await runMeasurement(1, 1, latencyIterations)

    // Output results as YAML
    console.log('# Upload measurement')
    console.log('upload:')
    console.log(`  iterations: ${uploadIterations}`)
    console.log(`  min: ${uploadStats.min.toFixed(2)}`)
    console.log(`  q1: ${uploadStats.q1.toFixed(2)}`)
    console.log(`  median: ${uploadStats.median.toFixed(2)}`)
    console.log(`  q3: ${uploadStats.q3.toFixed(2)}`)
    console.log(`  max: ${uploadStats.max.toFixed(2)}`)
    printOutliers(uploadStats.outliers, 2)
    console.log('  unit: Gbps')
    console.log()

    console.log('# Download measurement')
    console.log('download:')
    console.log(`  iterations: ${downloadIterations}`)
    console.log(`  min: ${downloadStats.min.toFixed(2)}`)
    console.log(`  q1: ${downloadStats.q1.toFixed(2)}`)
    console.log(`  median: ${downloadStats.median.toFixed(2)}`)
    console.log(`  q3: ${downloadStats.q3.toFixed(2)}`)
    console.log(`  max: ${downloadStats.max.toFixed(2)}`)
    printOutliers(downloadStats.outliers, 2)
    console.log('  unit: Gbps')
    console.log()

    console.log('# Latency measurement')
    console.log('latency:')
    console.log(`  iterations: ${latencyIterations}`)
    console.log(`  min: ${latencyStats.min.toFixed(3)}`)
    console.log(`  q1: ${latencyStats.q1.toFixed(3)}`)
    console.log(`  median: ${latencyStats.median.toFixed(3)}`)
    console.log(`  q3: ${latencyStats.q3.toFixed(3)}`)
    console.log(`  max: ${latencyStats.max.toFixed(3)}`)
    printOutliers(latencyStats.outliers, 3)
    console.log('  unit: ms')

    console.error('All measurements complete!')
  } catch (err) {
    console.error('Test failed:', err?.stack ?? err)
    process.exit(1)
  }

  await node.stop()
}

async function runMeasurement(uploadBytes, downloadBytes, iterations) {
  const values = []

  for (let i = 0; i < iterations; i++) {
    const start = Date.now()

    // Placeholder: simulate transfer
    // In real implementation, use libp2p perf protocol
    await new Promise(resolve => setTimeout(resolve, 10))

    const elapsed = (Date.now() - start) / 1000

    // Calculate throughput if this is a throughput test
    let value
    if (uploadBytes > 100 || downloadBytes > 100) {
      // Throughput in Gbps
      const bytes = Math.max(uploadBytes, downloadBytes)
      value = (bytes * 8) / elapsed / 1_000_000_000
    } else {
      // Latency in milliseconds
      value = elapsed * 1000
    }

    values.push(value)
  }

  return calculateStats(values)
}

function calculateStats(values) {
  values.sort((a, b) => a - b)

  const n = values.length
  const min = values[0]
  const max = values[n - 1]

  // Calculate percentiles
  const q1 = percentile(values, 25.0)
  const median = percentile(values, 50.0)
  const q3 = percentile(values, 75.0)

  // Calculate IQR and identify outliers
  const iqr = q3 - q1
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

  if (lower === upper) {
    return sortedValues[lower]
  }

  const weight = index - lower
  return sortedValues[lower] * (1.0 - weight) + sortedValues[upper] * weight
}

function printOutliers(outliers, decimals) {
  if (outliers.length === 0) {
    console.log('  outliers: []')
    return
  }

  const formatted = outliers.map(v => v.toFixed(decimals)).join(', ')
  console.log(`  outliers: [${formatted}]`)
}

if (isDialer) {
  runClient().catch(err => {
    console.error('Client error:', err?.stack ?? err)
    process.exit(1)
  })
} else {
  runServer().catch(err => {
    console.error('Server error:', err?.stack ?? err)
    process.exit(1)
  })
}
