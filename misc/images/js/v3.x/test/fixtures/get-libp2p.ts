/* eslint-disable complexity */
import { noise } from '@chainsafe/libp2p-noise'
import { yamux } from '@chainsafe/libp2p-yamux'
import { identify } from '@libp2p/identify'
import { mplex } from '@libp2p/mplex'
import { ping } from '@libp2p/ping'
import { tcp } from '@libp2p/tcp'
import { webSockets } from '@libp2p/websockets'
import { createLibp2p } from 'libp2p'
import type { Identify } from '@libp2p/identify'
import type { Libp2p } from '@libp2p/interface'
import type { Ping } from '@libp2p/ping'
import type { Libp2pOptions } from 'libp2p'

// Test framework env vars (uppercase)
const isDialer: boolean = process.env.IS_DIALER === 'true'

const TRANSPORT = process.env.TRANSPORT
if (!TRANSPORT) { throw new Error('TRANSPORT environment variable is required') }

const SECURE_CHANNEL = process.env.SECURE_CHANNEL
const MUXER = process.env.MUXER
const IP = process.env.LISTENER_IP
if (!IP) { throw new Error('LISTENER_IP environment variable is required') }

export type MiscNode = Libp2p<{ ping: Ping, identify: Identify }>

export async function getLibp2p (): Promise<MiscNode> {
  const options: Libp2pOptions<{ ping: Ping, identify: Identify }> = {
    start: true,
    connectionGater: { denyDialMultiaddr: async () => false },
    connectionMonitor: { enabled: false },
    services: {
      ping: ping(),
      identify: identify()
    }
  }

  // ── Transport ──────────────────────────────────────────────────────────────
  switch (TRANSPORT) {
    case 'tcp':
      options.transports = [tcp()]
      options.addresses = { listen: isDialer ? [] : [`/ip4/${IP}/tcp/0`] }
      break
    case 'ws':
      options.transports = [webSockets()]
      options.addresses = { listen: isDialer ? [] : [`/ip4/${IP}/tcp/0/ws`] }
      break
    default:
      throw new Error(`Unsupported transport for misc tests: ${TRANSPORT}`)
  }

  // ── Security ───────────────────────────────────────────────────────────────
  switch (SECURE_CHANNEL) {
    case 'noise':
      options.connectionEncrypters = [noise()]
      break
    default:
      throw new Error(`Unsupported secure channel for misc tests: ${SECURE_CHANNEL ?? '(none)'}`)
  }

  // ── Muxer ─────────────────────────────────────────────────────────────────
  switch (MUXER) {
    case 'yamux':
      options.streamMuxers = [yamux()]
      break
    case 'mplex':
      options.streamMuxers = [mplex()]
      break
    default:
      throw new Error(`Unsupported muxer for misc tests: ${MUXER ?? '(none)'}`)
  }

  return createLibp2p(options)
}
