/* eslint-disable complexity */

// import { quic } from '@chainsafe/libp2p-quic'
import { circuitRelayTransport } from '@libp2p/circuit-relay-v2'
import { identify } from '@libp2p/identify'
import { defaultLogger, enable } from '@libp2p/logger'
import { mplex } from '@libp2p/mplex'
import { noise } from '@libp2p/noise'
import { ping } from '@libp2p/ping'
import { tcp } from '@libp2p/tcp'
import { tls } from '@libp2p/tls'
import { webRTC, webRTCDirect } from '@libp2p/webrtc'
import { webSockets } from '@libp2p/websockets'
import { webTransport } from '@libp2p/webtransport'
import { yamux } from '@libp2p/yamux'
import { createLibp2p } from 'libp2p'
import type { Identify } from '@libp2p/identify'
import type { ComponentLogger, Libp2p, Logger } from '@libp2p/interface'
import type { Ping } from '@libp2p/ping'
import type { Libp2pOptions } from 'libp2p'

// Test framework sets uppercase env vars (IS_DIALER, TRANSPORT, SECURE_CHANNEL, MUXER, LISTENER_IP)
const isDialer: boolean = process.env.IS_DIALER === 'true'

// Setup libp2p node
const TRANSPORT = process.env.TRANSPORT
if (!TRANSPORT) {
  throw new Error('TRANSPORT environment variable is required')
}
const SECURE_CHANNEL = process.env.SECURE_CHANNEL
const MUXER = process.env.MUXER
const IP = process.env.LISTENER_IP
if (!IP) {
  throw new Error('LISTENER_IP environment variable is required')
}

// Optional: force the WebRTC Direct dialer to one version of the connection
// flow (dialing only; listeners accept both). Unset, js-libp2p tries v1 and
// continues as v2 when the runtime does not apply munged ICE credentials (e.g.
// Chromium with WebRTC-NoSdpMangleUfrag); later dials then start at v2.
const WEBRTC_DIRECT_DIALER_VERSION = process.env.WEBRTC_DIRECT_DIALER_VERSION
let webRTCDirectDialerVersion: 1 | 2 | undefined
if (WEBRTC_DIRECT_DIALER_VERSION === '1' || WEBRTC_DIRECT_DIALER_VERSION === '2') {
  webRTCDirectDialerVersion = WEBRTC_DIRECT_DIALER_VERSION === '1' ? 1 : 2
} else if (WEBRTC_DIRECT_DIALER_VERSION != null && WEBRTC_DIRECT_DIALER_VERSION !== '') {
  throw new Error(`Unknown WEBRTC_DIRECT_DIALER_VERSION: ${WEBRTC_DIRECT_DIALER_VERSION}`)
}

// The WebRTC Direct version the last dial used, read from the transport's log
// calls since libp2p does not expose it. The dialer test compares it with
// EXPECT_WEBRTC_DIRECT_VERSION, so a dial that silently uses the other version
// fails instead of passing.
//
// This matches the @libp2p/webrtc 7.0.3 messages 'dial %a starting as WebRTC
// Direct v%d' (the version is the second argument), 'runtime rejected the
// munged local offer' and '... continuing as WebRTC Direct v2'. If an upgrade
// rewords them, the dialer test fails with "an unknown version" or a version
// mismatch; update the strings in trackWebRTCDirectVersion. They are logged
// by the libp2p:webrtc-direct component logger itself, not a newScope() one.
let webRTCDirectDialedVersion: number | undefined

export function getWebRTCDirectDialedVersion (): number | undefined {
  return webRTCDirectDialedVersion
}

// DEBUG may hold namespaces when run by hand; the framework sets it to "true"
// or "false" (--debug), which are not namespaces
function debugNamespaces (): string {
  const debug = process.env.DEBUG ?? ''
  return debug === 'true' || debug === 'false' ? '' : debug
}

function trackWebRTCDirectVersion (logger: ComponentLogger): ComponentLogger {
  return {
    forComponent (name: string): Logger {
      const log = logger.forComponent(name)

      if (name !== 'libp2p:webrtc-direct') {
        return log
      }

      const tracked = (formatter: any, ...args: any[]): void => {
        if (typeof formatter === 'string') {
          if (formatter.includes('starting as WebRTC Direct v%d')) {
            webRTCDirectDialedVersion = args[1]
          } else if (formatter.includes('continuing as WebRTC Direct v2') || formatter.includes('rejected the munged local offer')) {
            // either message means this dial cannot stay on v1: an explicit v1
            // dial then fails, an unpinned one continues as v2
            webRTCDirectDialedVersion = 2
          }
        }

        log(formatter, ...args)
      }

      return Object.defineProperty(Object.assign(tracked, {
        error: log.error,
        trace: log.trace,
        newScope: log.newScope
      }), 'enabled', {
        get: () => log.enabled
      }) as Logger
    }
  }
}

export async function getLibp2p (): Promise<Libp2p<{ ping: Ping }>> {
  webRTCDirectDialedVersion = undefined

  const options: Libp2pOptions<{ ping: Ping, identify: Identify }> = {
    start: true,
    logger: trackWebRTCDirectVersion(defaultLogger()),
    connectionGater: {
      denyDialMultiaddr: async () => false
    },
    connectionMonitor: {
      enabled: false
    },
    services: {
      ping: ping(),
      identify: identify()
    }
  }

  switch (TRANSPORT) {
    case 'tcp':
      options.transports = [tcp()]
      options.addresses = {
        listen: isDialer ? [] : [`/ip4/${IP}/tcp/0`]
      }
      break
    case 'webtransport':
      options.transports = [webTransport()]
      if (!isDialer) {
        throw new Error('WebTransport is not supported as a listener')
      }
      break
    case 'webrtc-direct':
      options.transports = [webRTCDirect({ dialerVersion: webRTCDirectDialerVersion })]
      // Print which version each dial starts as and any fallback to v2
      // (dialers), or the version of each incoming STUN packet (listeners,
      // trace level), so the test output shows the version on both sides. The
      // dialer's version check reads the log calls whether or not they are
      // printed. Must run before createLibp2p, which creates the loggers.
      enable([
        debugNamespaces(),
        isDialer ? 'libp2p:webrtc-direct' : 'libp2p:webrtc-direct:listener:trace'
      ].filter(Boolean).join(','))
      options.addresses = {
        listen: isDialer ? [] : [`/ip4/${IP}/udp/0/webrtc-direct`]
      }
      break
    case 'webrtc':
      options.transports = [
        webRTC(),
        webSockets(), // ws needed to connect to relay
        circuitRelayTransport()
      ]
      options.addresses = {
        listen: isDialer ? [] : ['/p2p-circuit', '/webrtc']
      }
      break
    case 'ws':
      options.transports = [webSockets()]
      options.addresses = {
        listen: isDialer ? [] : [`/ip4/${IP}/tcp/0/ws`]
      }
      break
    case 'wss':
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'
      options.transports = [webSockets()]
      options.addresses = {
        listen: isDialer ? [] : [`/ip4/${IP}/tcp/0/wss`]
      }
      break
    // TODO: re-enable quic after v3 release
    // case 'quic-v1':
    //   options.transports = [quic()]
    //   options.addresses = {
    //     listen: isDialer ? [] : [`/ip4/${IP}/udp/0/quic-v1`]
    //   }
    //   break
    default:
      throw new Error(`Unknown transport: ${TRANSPORT ?? '???'}`)
  }

  let skipSecureChannel = false
  let skipMuxer = false
  switch (TRANSPORT) {
    case 'webtransport':
    case 'webrtc-direct':
    // TODO: re-enable quic after v3 release
    // case 'quic-v1':
      skipSecureChannel = true
      skipMuxer = true
      break
    case 'webrtc':
      skipSecureChannel = true
      skipMuxer = true
      // Setup yamux and noise to connect to the relay node
      options.streamMuxers = [yamux()]
      options.connectionEncrypters = [noise()]
      break
    default:
      // Do nothing
  }

  if (!skipSecureChannel) {
    switch (SECURE_CHANNEL) {
      case 'noise':
        options.connectionEncrypters = [noise()]
        break
      case 'tls':
        options.connectionEncrypters = [tls()]
        break
      default:
        throw new Error(`Unknown secure channel: ${SECURE_CHANNEL ?? ''} for transport ${TRANSPORT ?? ''}`)
    }
  }

  if (!skipMuxer) {
    switch (MUXER) {
      case 'mplex':
        options.streamMuxers = [mplex()]
        break
      case 'yamux':
        options.streamMuxers = [yamux()]
        break
      default:
        throw new Error(`Unknown muxer: ${MUXER ?? '???'}`)
    }
  }

  return createLibp2p(options)
}
