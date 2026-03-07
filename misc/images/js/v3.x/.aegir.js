/* eslint-disable no-console */
import http from 'http'
import { pEvent } from 'p-event'
import { createClient } from 'redis'

// Test framework sets uppercase env vars (REDIS_ADDR, TRANSPORT, IS_DIALER, PROTOCOL)
// Validated in the before() hook (not at module load time) because .aegir.js
// is loaded during the Docker build when env vars are not yet available.

/** @type {import('aegir/types').PartialOptions} */
export default {
  test: {
    async before () {
      const redisAddr = process.env.REDIS_ADDR
      if (!redisAddr) {
        throw new Error('REDIS_ADDR environment variable is required')
      }
      const transport = process.env.TRANSPORT
      if (!transport) {
        throw new Error('TRANSPORT environment variable is required')
      }
      const protocol = process.env.PROTOCOL
      if (!protocol) {
        throw new Error('PROTOCOL environment variable is required')
      }
      const isDialer = process.env.IS_DIALER === 'true'

      const redisClient = createClient({ url: `redis://${redisAddr}` })
      redisClient.on('error', (err) => {
        console.error('Redis client error:', err)
      })

      let start = Date.now()
      console.error('connect redis client')
      await redisClient.connect()
      console.error('connected redis client after', Date.now() - start, 'ms')

      // HTTP proxy so test code can issue Redis commands via fetch()
      const requestListener = async function (req, res) {
        let requestJSON
        try {
          requestJSON = await new Promise((resolve, reject) => {
            let body = ''
            req.on('data', (data) => { body += data })
            req.on('end', () => {
              try { resolve(JSON.parse(body)) } catch (e) { reject(e) }
            })
            req.on('error', reject)
          })
        } catch (parseError) {
          res.writeHead(400, { 'Access-Control-Allow-Origin': '*' })
          res.end(JSON.stringify({ message: `Invalid request: ${parseError.message}` }))
          return
        }

        try {
          const redisRes = await redisClient.sendCommand(requestJSON)
          const command = requestJSON[0]?.toUpperCase()
          if (redisRes == null && command !== 'GET' && command !== 'BLPOP') {
            res.writeHead(500, { 'Access-Control-Allow-Origin': '*' })
            res.end(JSON.stringify({ message: 'Redis sent back null' }))
            return
          }
          res.writeHead(200, { 'Access-Control-Allow-Origin': '*' })
          res.end(JSON.stringify(redisRes))
        } catch (err) {
          console.error('Error in redis command:', err)
          res.writeHead(500, { 'Access-Control-Allow-Origin': '*' })
          res.end(err.toString())
        }
      }

      start = Date.now()
      const proxyServer = http.createServer(requestListener)
      proxyServer.listen(0)
      await pEvent(proxyServer, 'listening', { signal: AbortSignal.timeout(30_000) })
      console.error('redis proxy listening on port', proxyServer.address().port, 'after', Date.now() - start, 'ms')

      return {
        redisClient,
        proxyServer,
        env: {
          ...process.env,
          REDIS_PROXY_PORT: String(proxyServer.address().port)
        }
      }
    },

    async after (_, { proxyServer, redisClient }) {
      await new Promise(resolve => { proxyServer?.close(() => resolve(undefined)) })
      try { await redisClient.disconnect() } catch {}
    }
  }
}
