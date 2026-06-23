# Hole-Punch Test Routers: OpenBSD QEMU Implementation

This document describes how the OpenBSD router Docker image is built and how
packets flow from Docker networks through Linux bridges and QEMU TAP interfaces
into an OpenBSD VM running PF NAT — and back again.

## Overview

The hole-punch interop tests place a **relay**, two **routers**, a **dialer**,
and a **listener** on isolated Docker networks. Each router performs NAT between
a WAN network (shared with the relay) and a private LAN network (shared with
its peer). The routers come in two flavours:

| Router   | Forwarding layer          | NAT engine       |
|----------|---------------------------|-------------------|
| Linux    | L3 in container (iptables) | iptables MASQUERADE |
| OpenBSD  | L2 bridge in container, L3 inside QEMU VM | OpenBSD PF `nat-to` |

The Linux router is straightforward: it runs iptables directly in the
container. The OpenBSD router is more complex because OpenBSD cannot run
natively in a container — it must run inside a QEMU virtual machine, with the
container acting as a bridge between Docker's networks and the VM's virtual
NICs.

## Network topology

```
                        WAN network (10.x.x.64/27)
            ┌───────────────────┬────────────────────┐
            │                   │                    │
         wan0(.66)          wan0(.68)            wan0(.67)
     ┌──────┴──────┐     ┌──────┴──────┐     ┌──────┴──────┐
     │ Dialer      │     │   Relay     │     │  Listener   │
     │ Router      │     │             │     │  Router     │
     └──────┬──────┘     └─────────────┘     └──────┬──────┘
         lan0(.98)                               lan0(.130)
            │                                       │
     LAN network                             LAN network
     (10.x.x.96/27)                          (10.x.x.128/27)
            │                                       │
         lan0(.99)                               lan0(.131)
     ┌──────┴──────┐                         ┌──────┴──────┐
     │   Dialer    │                         │  Listener   │
     └─────────────┘                         └─────────────┘
```

Docker Compose assigns the interface names `wan0` and `lan0` via
`interface_name:` in the network config.

## Docker image build (two-stage Dockerfile)

The OpenBSD image uses a multi-stage Docker build. The first stage installs
OpenBSD into a virtual hard disk at build time so that every container start
boots from a pre-installed image rather than running the installer.

### Stage 1: Installer

Base image: `debian:13-slim` with QEMU, wget, and python3.

1. **Download PXE boot files** from `cdn.openbsd.org` — `pxeboot`, `bsd.rd`,
   and the `auto_install` symlink that triggers unattended installation.

2. **Download install sets** (`base78.tgz`, `comp78.tgz`, `man78.tgz`,
   kernels, SHA256) into a local mirror directory at
   `/tftp/pub/OpenBSD/7.8/amd64/`.

3. **Build `site78.tgz`** — a custom set containing files that are extracted
   to `/` on the target after the base sets:
   - `etc/pf.conf` — PF firewall rules
   - `etc/rc.local` — boot-time network configuration script
   - `etc/rc.conf.local` — enables PF (`pf=YES`)
   - `etc/firstboot_halt` — sentinel file for the two-boot optimisation
   - `install.site` — post-install hook script

4. **Create a 4 GB qcow2 virtual HDD** (`/disks/hdd.qcow2`).

5. **First QEMU boot — PXE install.** A Python HTTP server serves the
   install sets from `/tftp/`. QEMU boots via PXE using user-mode networking
   (`-netdev user`) with built-in TFTP. The `install.conf` answer file drives
   the unattended install. OpenBSD installs to the virtio disk and reboots
   (QEMU exits due to `-no-reboot`).

6. **Second QEMU boot — consume `rc.firsttime`.** OpenBSD runs first-boot
   tasks (SSH key generation, `ldconfig`, `sysmerge`). The `firstboot_halt`
   sentinel causes `rc.local` to call `halt -p` once these complete, and
   `-no-reboot` causes QEMU to exit. This ensures runtime boots are fast
   because all one-time setup is already done.

### Stage 2: Runtime

Base image: `debian:13-slim` with runtime packages only:
`qemu-system-x86`, `qemu-utils`, `bridge-utils`, `iproute2`, `genisoimage`,
`procps`.

The pre-installed qcow2 disk is copied from the installer stage. The
entrypoint script and healthcheck are added.

```dockerfile
HEALTHCHECK --interval=2s --timeout=2s --start-period=120s --retries=1 \
    CMD test -f /tmp/healthy
```

## OpenBSD VM configuration files

### `install.conf`

OpenBSD autoinstall answer file. Key choices:
- Hostname: `openbsd-router`
- Single NIC during install (`vio0` with DHCP via QEMU user-mode networking)
- Serial console on `com0` at 115200 baud
- Installs `base78`, `comp78`, `man78`, and `site78` sets (no X11, no games)
- Root disk: `sd0`, whole-disk MBR, auto layout

### `boot.conf`

Directs the bootloader to use the serial console:

```
set tty com0
stty com0 115200
```

### `install.site`

Post-install hook that runs after set extraction:
- Enables IP forwarding persistently: `net.inet.ip.forwarding=1` in
  `sysctl.conf`
- Removes the DHCP-based `hostname.vio0` from the install (the runtime
  `rc.local` configures interfaces dynamically from the config drive)

### `rc.conf.local`

```
pf=YES
```

Ensures the PF firewall is enabled at boot.

### `pf.conf`

```
set block-policy drop
set skip on lo

match out on vio0 from vio1:network nat-to (vio0)

block all
pass out all keep state
pass in on vio1 all keep state
```

- `match out ... nat-to` — rewrites the source address of LAN traffic to the
  WAN IP (equivalent to iptables MASQUERADE)
- `block all` — default deny
- `pass out all keep state` — allows outbound traffic and creates stateful
  entries for return traffic
- `pass in on vio1 all keep state` — allows all traffic originating from the
  LAN side

### `rc.local`

Runs at every boot (after the firstboot sentinel is consumed). It:

1. Mounts the config drive ISO from `/dev/cd0a`
2. Copies `hostname.vio0`, `hostname.vio1`, and `mygate` into `/etc/`
3. Brings up both interfaces with `sh /etc/netstart vio0` and
   `sh /etc/netstart vio1`
4. Adds the default route from `/etc/mygate`
5. Enables IP forwarding (`sysctl net.inet.ip.forwarding=1`)
6. Loads PF rules (`pfctl -f /etc/pf.conf`)
7. Prints `"rc.local: Network configuration complete."` — this marker string
   is what the entrypoint polls for to signal readiness

## Container entrypoint: bridge + TAP + QEMU launch

When the container starts, `entrypoint.sh` runs as PID 1 inside a
`debian:13-slim` container. Docker has already attached two veth interfaces
named `wan0` and `lan0` with IPs assigned by Compose. The entrypoint must
bridge these into the QEMU VM so that the OpenBSD guest takes over the IP
addresses.

### Step-by-step

#### 1. Capture network metadata

The entrypoint reads environment variables (`WAN_IP`, `WAN_SUBNET`, `LAN_IP`,
`LAN_SUBNET`) set by Compose. It computes netmasks and broadcast addresses,
extracts the WAN default gateway from the routing table, and records the MAC
addresses of `wan0` and `lan0`.

The MAC addresses are critical — they are passed to QEMU so the VM's virtual
NICs have the same MACs that Docker expects. Without this, ARP resolution on
the Docker bridge networks would fail.

#### 2. Create TAP interfaces

```bash
ip tuntap add tap0 mode tap
ip tuntap add tap1 mode tap
```

TAP devices are virtual Ethernet ports. QEMU reads/writes Ethernet frames
directly to them. Requires `/dev/net/tun` (created if missing) and
`NET_ADMIN` capability.

#### 3. Create Linux bridges

```
br-wan:  wan0 + tap0     (WAN side)
br-lan:  lan0 + tap1     (LAN side)
```

Each bridge connects a Docker veth to a QEMU TAP, creating a Layer 2 link.

```bash
ip link add br-wan type bridge
ip link set wan0 master br-wan
ip link set tap0 master br-wan
ip addr flush dev wan0          # Remove IP — the VM owns it now
ip link set wan0 up
ip link set br-wan up
```

Same for `br-lan` with `lan0` and `tap1`.

Flushing the IP from the Docker interface is essential. The OpenBSD VM will
configure these IPs on its `vio0`/`vio1` interfaces. If the Linux side also
has the IP, there would be duplicate addresses and routing confusion.

#### 4. Disable bridge netfilter and rp_filter

Docker loads the `br_netfilter` kernel module on the host for its own network
isolation. This causes packets traversing *any* Linux bridge — including
bridges inside containers — to pass through the container's iptables/nftables
FORWARD chain. This can silently drop bridged frames.

```bash
# Per-bridge sysfs (always available)
for br in br-wan br-lan; do
    for f in nf_call_iptables nf_call_ip6tables nf_call_arptables; do
        [ -f "/sys/class/net/$br/bridge/$f" ] && \
            echo 0 > "/sys/class/net/$br/bridge/$f"
    done
done

# Namespace-wide (only exists if br_netfilter is loaded)
for f in /proc/sys/net/bridge/bridge-nf-call-iptables \
         /proc/sys/net/bridge/bridge-nf-call-ip6tables \
         /proc/sys/net/bridge/bridge-nf-call-arptables; do
    [ -f "$f" ] && echo 0 > "$f" 2>/dev/null || true
done
```

Reverse path filtering (`rp_filter`) is also disabled on all interfaces.
Even though Compose sets `net.ipv4.conf.default.rp_filter=0`, interfaces
created *after* the container starts (bridges, TAPs) inherit the default at
creation time and may have stale values.

```bash
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$f" 2>/dev/null || true
done
```

#### 5. Build the config drive ISO

The entrypoint generates OpenBSD `hostname.if` files and a `mygate` file
from the Docker-assigned network parameters, then packs them into an ISO
using `genisoimage`:

```
hostname.vio0: inet 10.x.x.66 255.255.255.224 10.x.x.95
hostname.vio1: inet 10.x.x.98 255.255.255.224 10.x.x.127
mygate:        10.x.x.65
```

This ISO is attached to QEMU as a CD-ROM. The OpenBSD `rc.local` mounts it
at boot and copies the files into `/etc/`.

#### 6. Launch QEMU

```bash
qemu-system-x86_64 \
    -m 512M \
    $ENABLE_KVM \
    -drive file=/hdd.qcow2,if=virtio,format=qcow2 \
    -cdrom /config.iso \
    -netdev tap,id=net0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0,mac="$WAN_MAC" \
    -netdev tap,id=net1,ifname=tap1,script=no,downscript=no \
    -device virtio-net-pci,netdev=net1,mac="$LAN_MAC" \
    -nographic \
    -serial file:/tmp/console.log &
```

Key options:
- **`-netdev tap ... script=no`** — uses the pre-created TAP devices; no
  helper scripts (the entrypoint already configured the bridges)
- **`mac="$WAN_MAC"` / `mac="$LAN_MAC"`** — VM NICs get the same MAC
  addresses Docker assigned to `wan0`/`lan0`, so ARP works correctly on the
  Docker bridge networks
- **`-cdrom /config.iso`** — the config drive with dynamic network settings
- **`-serial file:/tmp/console.log`** — serial output written to a file;
  the entrypoint tails this to Docker logs and polls it for the readiness
  marker
- **`$ENABLE_KVM`** — uses KVM hardware acceleration if `/dev/kvm` exists

#### 7. Wait for boot and signal health

The entrypoint polls `/tmp/console.log` for the string
`"rc.local: Network configuration complete."` with a 120-second timeout.
When found, it touches `/tmp/healthy`, which satisfies the Docker
`HEALTHCHECK`. Docker Compose `depends_on` with `condition: service_healthy`
gates the dialer/listener containers on this.

SIGTERM/SIGINT are trapped and forwarded to the QEMU process for graceful
shutdown.

## Full packet path

A TCP connection from the dialer to the relay traverses this path:

```
Dialer container
    │
    │ lan0 (10.x.x.99)
    │ veth on Docker "dialer-lan" bridge
    │
    ▼
Dialer Router container
    │
    │ lan0 ──► br-lan ──► tap1
    │              Linux bridge (L2)
    │
    ▼
OpenBSD VM (vio1 = LAN)
    │ IP forwarding + PF NAT
    │ src rewritten: 10.x.x.99 → 10.x.x.66 (WAN IP)
    │
    ▼
OpenBSD VM (vio0 = WAN)
    │
    │ tap0 ◄── br-wan ◄── wan0
    │              Linux bridge (L2)
    │
    ▼
Dialer Router container
    │
    │ wan0 (MAC-matched, IP owned by VM)
    │ veth on Docker "wan" bridge
    │
    ▼
Relay container
    │ wan0 (10.x.x.68)
```

Return traffic follows the reverse path. PF's `keep state` rules create
bidirectional state entries, so return packets are automatically de-NATed.

## Container capabilities and sysctls

The Compose configuration grants the router containers:

```yaml
cap_add:
  - NET_ADMIN
devices:
  - /dev/net/tun:/dev/net/tun
  - /dev/kvm:/dev/kvm        # optional, for acceleration
sysctls:
  - net.ipv4.ip_forward=1
  - net.ipv4.conf.all.forwarding=1
  - net.ipv4.conf.default.forwarding=1
  - net.ipv4.conf.all.rp_filter=0
  - net.ipv4.conf.default.rp_filter=0
```

`NET_ADMIN` is required for creating bridges, TAP interfaces, and
manipulating network configuration. `/dev/net/tun` is required for QEMU's TAP
backend. `/dev/kvm` enables hardware-assisted virtualisation when the host
supports it.

## Comparison with the Linux router

| Aspect             | Linux router              | OpenBSD router                    |
|--------------------|---------------------------|-----------------------------------|
| Base image         | Alpine 3.19               | Debian 13-slim + QEMU            |
| NAT engine         | iptables MASQUERADE       | OpenBSD PF `nat-to`              |
| Forwarding         | L3 in container           | L2 bridge in container, L3 in VM |
| Boot time          | Instant                   | ~30-60s (QEMU + OpenBSD boot)    |
| Healthcheck        | Not needed (instant)      | Polls serial console for marker  |
| Extra devices      | None                      | `/dev/net/tun`, `/dev/kvm`       |
| Compose dependency | Simple `depends_on`       | `depends_on` with `condition: service_healthy` |

## Troubleshooting

If TCP connections through the OpenBSD router time out, check these inside the
router container:

```bash
# Bridge netfilter should be disabled (0 or file not found)
cat /sys/class/net/br-wan/bridge/nf_call_iptables
cat /proc/sys/net/bridge/bridge-nf-call-iptables

# Reverse path filtering should be 0 on all interfaces
cat /proc/sys/net/ipv4/conf/br-wan/rp_filter
cat /proc/sys/net/ipv4/conf/tap0/rp_filter

# No DROP rules in iptables FORWARD chain
iptables -L FORWARD -n -v

# No nftables rules blocking traffic
nft list ruleset

# QEMU process should be running
ps aux | grep qemu

# OpenBSD console output (boot log, PF rules, interface state)
cat /tmp/console.log
```

Inside the OpenBSD VM (via serial console or `console.log`), verify:
- `ifconfig vio0` / `ifconfig vio1` — interfaces are up with correct IPs
- `pfctl -sr` — PF rules are loaded
- `sysctl net.inet.ip.forwarding` — returns `1`
- `route -n show` — default route points to the Docker bridge gateway
