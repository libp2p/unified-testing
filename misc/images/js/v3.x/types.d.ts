// Type declarations for packages without built-in TypeScript support

declare module '@multiformats/multiaddr' {
  export interface Multiaddr {
    toString(): string
    bytes: Uint8Array
    protoCodes(): number[]
    protoNames(): string[]
    tuples(): Array<[number, Uint8Array | null]>
    stringTuples(): Array<[number, string | null]>
    encapsulate(addr: Multiaddr | string): Multiaddr
    decapsulate(addr: Multiaddr | string): Multiaddr
    getPeerId(): string | null
    getPath(): string | null
    equals(other: Multiaddr): boolean
    inspect(): string
    isThinWaistAddress(): boolean
    nodeAddress(): { family: 4 | 6, address: string, port: number }
  }

  export function multiaddr (addr?: string | Uint8Array | Multiaddr): Multiaddr
  export { Multiaddr }
}
