/**
 * redis-proxy.ts
 * Send Redis commands through the local HTTP proxy started in .aegir.js.
 */
export async function redisProxy (commands: string[]): Promise<unknown> {
  const proxyPort = process.env.REDIS_PROXY_PORT
  if (!proxyPort) {
    throw new Error('REDIS_PROXY_PORT environment variable is required')
  }
  const res = await fetch(`http://localhost:${proxyPort}`, {
    method: 'POST',
    body: JSON.stringify(commands)
  })
  if (!res.ok) {
    const errorText = await res.text().catch(() => 'Unknown error')
    throw new Error(`Redis command failed: ${res.status} ${res.statusText} - ${errorText}`)
  }
  return res.json()
}
