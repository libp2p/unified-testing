/* eslint-disable no-console */
/* eslint-env mocha */

import { multiaddr } from '@multiformats/multiaddr'
import { getLibp2p } from './fixtures/get-libp2p.js'
import { redisProxy } from './fixtures/redis-proxy.js'
import type { MiscNode } from './fixtures/get-libp2p.js'
import type { Multiaddr } from '@multiformats/multiaddr'

const isDialer: boolean = process.env.IS_DIALER === 'true'
const PROTOCOL = process.env.PROTOCOL ?? 'ping'
const timeoutMs: number = parseInt(process.env.TEST_TIMEOUT_SECS ?? '180') * 1000

// ── Helper: pick the best listening address (prefer non-loopback) ──────────
function getBestMultiaddr (node: MiscNode): string {
  const sortByNonLocal = (a: Multiaddr, b: Multiaddr): -1 | 0 | 1 =>
    a.toString().includes('127.0.0.1') ? 1 : -1
  const addrs = node.getMultiaddrs().sort(sortByNonLocal)
  if (addrs.length === 0) { throw new Error('Node has no listening addresses') }
  return addrs[0].toString()
}

// ── Helper: publish multiaddr to Redis ────────────────────────────────────
async function publishMultiaddr (testKey: string, maStr: string): Promise<void> {
  const redisKey = `${testKey}_listener_multiaddr`
  try { await redisProxy(['DEL', redisKey]) } catch {}
  await redisProxy(['RPUSH', redisKey, maStr])
  console.error(`[listener] published multiaddr: ${maStr}`)
}

// ─────────────────────────────────────────────────────────────────────────────
// PING listener  (handles pings automatically via the ping service)
// ─────────────────────────────────────────────────────────────────────────────
describe('misc listener – ping', function () {
  if (isDialer || PROTOCOL !== 'ping') { return }

  this.timeout(timeoutMs + 30_000)
  let node: MiscNode

  beforeEach(async () => { node = await getLibp2p() })
  afterEach(async () => { try { await node.stop() } catch {} })

  it('should listen for ping', async function () {
    this.timeout(timeoutMs + 30_000)
    const testKey = process.env.TEST_KEY
    if (!testKey) { throw new Error('TEST_KEY environment variable is required') }

    const maStr = getBestMultiaddr(node)
    await publishMultiaddr(testKey, maStr)

    console.error('[ping] listener waiting…')
    await new Promise(resolve => setTimeout(resolve, timeoutMs))
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// ECHO listener  (registers /echo/1.0.0 and pipes streams back)
// ─────────────────────────────────────────────────────────────────────────────
describe('misc listener – echo', function () {
  if (isDialer || PROTOCOL !== 'echo') { return }

  this.timeout(timeoutMs + 30_000)
  let node: MiscNode

  beforeEach(async () => { node = await getLibp2p() })
  afterEach(async () => { try { await node.stop() } catch {} })

  it('should listen for echo', async function () {
    this.timeout(timeoutMs + 30_000)
    const testKey = process.env.TEST_KEY
    if (!testKey) { throw new Error('TEST_KEY environment variable is required') }

    // Register echo protocol handler: collect all bytes, then write them back
    await node.handle('/echo/1.0.0', async ({ stream }) => {
      try {
        const chunks: Uint8Array[] = []
        for await (const chunk of stream.source) {
          chunks.push(chunk instanceof Uint8Array ? chunk : chunk.subarray())
        }
        const totalLen = chunks.reduce((acc, c) => acc + c.length, 0)
        const data = new Uint8Array(totalLen)
        let offset = 0
        for (const c of chunks) { data.set(c, offset); offset += c.length }
        console.error(`[echo] echoing back ${data.length} bytes`)
        await stream.sink((async function * () { yield data })())
      } catch (err: any) {
        console.error(`[echo] handler error: ${err?.message ?? err}`)
      }
    })

    const maStr = getBestMultiaddr(node)
    await publishMultiaddr(testKey, maStr)

    console.error('[echo] listener ready, waiting for dialer…')
    await new Promise(resolve => setTimeout(resolve, timeoutMs))
  })
})

// ─────────────────────────────────────────────────────────────────────────────
// IDENTIFY listener  (identify runs automatically when a peer connects)
// ─────────────────────────────────────────────────────────────────────────────
describe('misc listener – identify', function () {
  if (isDialer || PROTOCOL !== 'identify') { return }

  this.timeout(timeoutMs + 30_000)
  let node: MiscNode

  beforeEach(async () => { node = await getLibp2p() })
  afterEach(async () => { try { await node.stop() } catch {} })

  it('should listen for identify', async function () {
    this.timeout(timeoutMs + 30_000)
    const testKey = process.env.TEST_KEY
    if (!testKey) { throw new Error('TEST_KEY environment variable is required') }

    const maStr = getBestMultiaddr(node)
    await publishMultiaddr(testKey, maStr)

    console.error('[identify] listener ready, waiting for dialer…')
    await new Promise(resolve => setTimeout(resolve, timeoutMs))
  })
})
