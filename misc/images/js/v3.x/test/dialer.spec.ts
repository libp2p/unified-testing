/* eslint-disable no-console */
/* eslint-env mocha */

import { multiaddr } from '@multiformats/multiaddr'
import { getLibp2p } from './fixtures/get-libp2p.js'
import { redisProxy } from './fixtures/redis-proxy.js'
import type { MiscNode } from './fixtures/get-libp2p.js'

const isDialer: boolean = process.env.IS_DIALER === 'true'
const PROTOCOL = process.env.PROTOCOL ?? 'ping'
const timeoutMs: number = parseInt(process.env.TEST_TIMEOUT_SECS ?? '180') * 1000

// ── Helper: read listener multiaddr from Redis ─────────────────────────────
async function getListenerAddr (testKey: string): Promise<string> {
  const redisKey = `${testKey}_listener_multiaddr`
  const waitSecs = Math.max(1, Math.floor(Math.min(timeoutMs / 1000, 180))).toString()
  const result = await redisProxy(['BLPOP', redisKey, waitSecs])
  if (!Array.isArray(result) || result.length < 2 || result[1] == null) {
    throw new Error(`Timeout waiting for listener address at Redis key: ${redisKey}`)
  }
  return String(result[1]).replace('/tls/ws', '/wss')
}

// ─────────────────────────────────────────────────────────────────────────────
// PING test (dialer side)
// Same behaviour as the transport interop ping test.
// ─────────────────────────────────────────────────────────────────────────────
describe(`misc dialer – ping`, function () {
  if (!isDialer || PROTOCOL !== 'ping') { return }

  this.timeout(timeoutMs + 30_000)
  let node: MiscNode

  beforeEach(async () => { node = await getLibp2p() })
  afterEach(async () => { try { await node.stop() } catch {} })

  it('should dial and ping', async function () {
    this.timeout(timeoutMs + 30_000)

    const testKey = process.env.TEST_KEY
    if (!testKey) { throw new Error('TEST_KEY environment variable is required') }

    const maStr = await getListenerAddr(testKey)
    const ma = multiaddr(maStr)
    const handshakeStart = Date.now()

    console.error(`[ping] dialer ${node.peerId} dials ${maStr}`)
    await node.dial(ma, { signal: AbortSignal.timeout(timeoutMs) })

    console.error(`[ping] dialer ${node.peerId} pings`)
    const pingRTT = await node.services.ping.ping(ma, { signal: AbortSignal.timeout(timeoutMs) })
    const handshakePlusOneRTT = Date.now() - handshakeStart

    console.log('latency:')
    console.log(`  handshake_plus_one_rtt: ${handshakePlusOneRTT}`)
    console.log(`  ping_rtt: ${pingRTT}`)
    console.log('  unit: ms')
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// ECHO test (dialer side)
// Opens a /echo/1.0.0 stream, sends a payload, reads back the echoed bytes,
// and verifies payload integrity.
// ─────────────────────────────────────────────────────────────────────────────
describe(`misc dialer – echo`, function () {
  if (!isDialer || PROTOCOL !== 'echo') { return }

  this.timeout(timeoutMs + 30_000)
  let node: MiscNode

  beforeEach(async () => { node = await getLibp2p() })
  afterEach(async () => { try { await node.stop() } catch {} })

  it('should send payload and receive echo', async function () {
    this.timeout(timeoutMs + 30_000)

    const testKey = process.env.TEST_KEY
    if (!testKey) { throw new Error('TEST_KEY environment variable is required') }

    const maStr = await getListenerAddr(testKey)
    const ma = multiaddr(maStr)

    console.error(`[echo] dialer dials ${maStr}`)
    const conn = await node.dial(ma, { signal: AbortSignal.timeout(timeoutMs) })

    // Open a stream for the echo protocol
    const stream = await conn.newStream(['/echo/1.0.0'], { signal: AbortSignal.timeout(timeoutMs) })

    // Build a test payload: "Hello from js-libp2p misc echo test!"
    const payload = new TextEncoder().encode('Hello from js-libp2p misc echo test!')
    console.error(`[echo] sending ${payload.length} bytes`)

    const echoStart = Date.now()

    // Write payload then close the write side
    const writer = stream.sink
    await writer((async function * () { yield payload })())

    // Read back the echoed bytes
    const chunks: Uint8Array[] = []
    for await (const chunk of stream.source) {
      chunks.push(chunk instanceof Uint8Array ? chunk : chunk.subarray())
    }

    const echoRTT = Date.now() - echoStart

    // Reassemble
    const totalLen = chunks.reduce((acc, c) => acc + c.length, 0)
    const echoed = new Uint8Array(totalLen)
    let offset = 0
    for (const c of chunks) { echoed.set(c, offset); offset += c.length }

    // Verify payload integrity
    const originalStr = new TextDecoder().decode(payload)
    const echoedStr = new TextDecoder().decode(echoed)

    if (originalStr !== echoedStr) {
      throw new Error(`Echo payload mismatch: sent "${originalStr}", received "${echoedStr}"`)
    }

    console.error(`[echo] verified ${echoed.length} bytes`)

    console.log('measurements:')
    console.log(`  echo_rtt: ${echoRTT}`)
    console.log(`  payload_bytes: ${payload.length}`)
    console.log('  unit: ms')
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// IDENTIFY test (dialer side)
// Dials the listener, waits for the identify push to arrive, and logs the
// protocol list the remote peer advertises.
// ─────────────────────────────────────────────────────────────────────────────
describe(`misc dialer – identify`, function () {
  if (!isDialer || PROTOCOL !== 'identify') { return }

  this.timeout(timeoutMs + 30_000)
  let node: MiscNode

  beforeEach(async () => { node = await getLibp2p() })
  afterEach(async () => { try { await node.stop() } catch {} })

  it('should dial and receive peer identify info', async function () {
    this.timeout(timeoutMs + 30_000)

    const testKey = process.env.TEST_KEY
    if (!testKey) { throw new Error('TEST_KEY environment variable is required') }

    const maStr = await getListenerAddr(testKey)
    const ma = multiaddr(maStr)
    const identifyStart = Date.now()

    console.error(`[identify] dialer dials ${maStr}`)
    const conn = await node.dial(ma, { signal: AbortSignal.timeout(timeoutMs) })
    const remotePeer = conn.remotePeer

    // Identify runs automatically on connection. Wait for the peer store to
    // be updated (signalled by the peer:update event) before reading protocols.
    const protocols = await new Promise<string[]>((resolve, reject) => {
      const abort = AbortSignal.timeout(timeoutMs)
      abort.addEventListener('abort', () => reject(new Error('Timeout waiting for identify')))

      const check = (): void => {
        node.peerStore.get(remotePeer).then((peer) => {
          if (peer != null && peer.protocols.length > 0) {
            resolve([...peer.protocols])
          }
        }).catch(() => {})
      }

      node.addEventListener('peer:update', () => check())
      check() // in case identify already completed before we registered the listener
    })

    const identifyRTT = Date.now() - identifyStart

    console.error(`[identify] remote peer ${remotePeer} advertises ${protocols.length} protocol(s)`)
    console.error(`[identify] protocols: ${protocols.join(', ')}`)

    if (protocols.length === 0) {
      throw new Error('Remote peer advertised no protocols via identify')
    }

    console.log('measurements:')
    console.log(`  identify_rtt: ${identifyRTT}`)
    console.log(`  protocol_count: ${protocols.length}`)
    console.log('  unit: ms')
  })
})
