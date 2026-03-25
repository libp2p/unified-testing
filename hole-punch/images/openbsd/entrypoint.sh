#!/bin/bash
# OpenBSD QEMU Router Entrypoint
# Sets up Linux bridges + TAP interfaces, creates a config drive ISO with
# dynamic network settings, and launches QEMU with MAC-matched NICs.

set -euo pipefail

echo "========================================"
echo "OpenBSD QEMU NAT Router"
echo "========================================"

# --- Required environment variables (passed by docker-compose) ---
WAN_IP="${WAN_IP:-}"
WAN_SUBNET="${WAN_SUBNET:-}"
LAN_IP="${LAN_IP:-}"
LAN_SUBNET="${LAN_SUBNET:-}"

if [ -z "$WAN_IP" ] || [ -z "$WAN_SUBNET" ] || [ -z "$LAN_IP" ] || [ -z "$LAN_SUBNET" ]; then
    echo "ERROR: Missing required environment variables"
    echo "Required: WAN_IP, WAN_SUBNET, LAN_IP, LAN_SUBNET"
    exit 1
fi

# Docker Compose assigns these interface names via interface_name:
WAN_IF="wan0"
LAN_IF="lan0"

echo "Configuration:"
echo "  WAN Interface: $WAN_IF  IP: $WAN_IP  Subnet: $WAN_SUBNET"
echo "  LAN Interface: $LAN_IF  IP: $LAN_IP  Subnet: $LAN_SUBNET"

# --- Helper: CIDR prefix to dotted netmask ---
cidr_to_mask() {
    local cidr=$1
    local mask=$(( 0xffffffff << (32 - cidr) ))
    printf "%d.%d.%d.%d" \
        $(( (mask >> 24) & 255 )) \
        $(( (mask >> 16) & 255 )) \
        $(( (mask >> 8) & 255 )) \
        $(( mask & 255 ))
}

# --- Helper: compute broadcast from IP and CIDR ---
compute_broadcast() {
    local ip=$1
    local cidr=$2
    local IFS='.'
    # shellcheck disable=SC2086
    set -- $ip
    local ip_int=$(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
    local hostmask=$(( (1 << (32 - cidr)) - 1 ))
    local bcast=$(( ip_int | hostmask ))
    printf "%d.%d.%d.%d" \
        $(( (bcast >> 24) & 255 )) \
        $(( (bcast >> 16) & 255 )) \
        $(( (bcast >> 8) & 255 )) \
        $(( bcast & 255 ))
}

# --- Extract CIDR prefix from subnet ---
WAN_CIDR="${WAN_SUBNET#*/}"
LAN_CIDR="${LAN_SUBNET#*/}"

WAN_MASK=$(cidr_to_mask "$WAN_CIDR")
LAN_MASK=$(cidr_to_mask "$LAN_CIDR")

WAN_BCAST=$(compute_broadcast "$WAN_IP" "$WAN_CIDR")
LAN_BCAST=$(compute_broadcast "$LAN_IP" "$LAN_CIDR")

echo "  WAN Mask: $WAN_MASK  Broadcast: $WAN_BCAST"
echo "  LAN Mask: $LAN_MASK  Broadcast: $LAN_BCAST"

# --- Extract WAN gateway from routing table ---
WAN_GW=$(ip route show default dev "$WAN_IF" 2>/dev/null | awk '{print $3}' | head -1)
if [ -z "$WAN_GW" ]; then
    # Fallback: first usable IP in WAN subnet (Docker bridge gateway)
    local_IFS="$IFS"; IFS='.'
    # shellcheck disable=SC2086
    set -- ${WAN_SUBNET%/*}
    WAN_GW="$1.$2.$3.$(( $4 + 1 ))"
    IFS="$local_IFS"
    echo "  WAN Gateway (fallback): $WAN_GW"
else
    echo "  WAN Gateway: $WAN_GW"
fi

# --- Capture MAC addresses BEFORE flushing IPs ---
WAN_MAC=$(ip link show "$WAN_IF" | awk '/ether/{print $2}')
LAN_MAC=$(ip link show "$LAN_IF" | awk '/ether/{print $2}')
echo "  WAN MAC: $WAN_MAC"
echo "  LAN MAC: $LAN_MAC"

# --- Create /dev/net/tun if needed ---
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    echo "Created /dev/net/tun"
fi

# --- Create TAP interfaces ---
ip tuntap add tap0 mode tap
ip tuntap add tap1 mode tap
ip link set tap0 up
ip link set tap1 up
echo "Created TAP interfaces"

# --- Create bridges and wire up ---
# WAN: wan0 <-> br-wan <-> tap0
ip link add br-wan type bridge
ip link set "$WAN_IF" master br-wan
ip link set tap0 master br-wan

# Flush IP from Docker interface (OpenBSD VM takes over)
ip addr flush dev "$WAN_IF"
ip link set "$WAN_IF" up
ip link set br-wan up

# LAN: lan0 <-> br-lan <-> tap1
ip link add br-lan type bridge
ip link set "$LAN_IF" master br-lan
ip link set tap1 master br-lan

ip addr flush dev "$LAN_IF"
ip link set "$LAN_IF" up
ip link set br-lan up

echo "Bridges configured: br-wan ($WAN_IF + tap0), br-lan ($LAN_IF + tap1)"

# --- Ensure transparent L2 forwarding for QEMU bridges ---
# Docker loads br_netfilter which causes bridged frames to traverse iptables
# FORWARD chain. Disable this for our bridges to prevent packet drops.
for br in br-wan br-lan; do
    for f in nf_call_iptables nf_call_ip6tables nf_call_arptables; do
        [ -f "/sys/class/net/$br/bridge/$f" ] && echo 0 > "/sys/class/net/$br/bridge/$f"
    done
done

# Also try namespace-wide sysctl (exists only if br_netfilter is loaded)
for f in /proc/sys/net/bridge/bridge-nf-call-iptables \
         /proc/sys/net/bridge/bridge-nf-call-ip6tables \
         /proc/sys/net/bridge/bridge-nf-call-arptables; do
    [ -f "$f" ] && echo 0 > "$f" 2>/dev/null || true
done

# Disable reverse path filtering on ALL interfaces (including newly created bridges/taps)
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
    echo 0 > "$f" 2>/dev/null || true
done

echo "Bridge netfilter disabled, rp_filter disabled on all interfaces"

# --- Create config drive ISO ---
CONFIG_DIR=$(mktemp -d)

# OpenBSD hostname.if format: inet <address> <netmask> <broadcast>
echo "inet $WAN_IP $WAN_MASK $WAN_BCAST" > "$CONFIG_DIR/hostname.vio0"
echo "inet $LAN_IP $LAN_MASK $LAN_BCAST" > "$CONFIG_DIR/hostname.vio1"
echo "$WAN_GW" > "$CONFIG_DIR/mygate"

echo "Config drive contents:"
echo "  hostname.vio0: $(cat "$CONFIG_DIR/hostname.vio0")"
echo "  hostname.vio1: $(cat "$CONFIG_DIR/hostname.vio1")"
echo "  mygate: $(cat "$CONFIG_DIR/mygate")"

genisoimage -quiet -r -V CONFIG -o /config.iso "$CONFIG_DIR"
rm -rf "$CONFIG_DIR"
echo "Config drive ISO created"

# --- Detect KVM ---
ENABLE_KVM=""
if [ -c /dev/kvm ]; then
    ENABLE_KVM="-enable-kvm"
    echo "KVM acceleration enabled"
else
    echo "KVM not available, using software emulation"
fi

echo "========================================"
echo "Launching OpenBSD QEMU VM..."
echo "========================================"

# --- Launch QEMU ---
# - virtio disk with installed OpenBSD
# - CD-ROM config drive (mounted by rc.local)
# - Two virtio NICs bridged to Docker networks via TAP, with matching MACs
# - Serial output to file for readiness detection; tail mirrors to docker logs
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
QEMU_PID=$!

# Mirror console output to docker logs
tail -f /tmp/console.log 2>/dev/null &
TAIL_PID=$!

# Forward SIGTERM/SIGINT to QEMU for graceful shutdown
cleanup_qemu() {
    echo "Forwarding signal to QEMU (PID $QEMU_PID)..."
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    kill "$TAIL_PID" 2>/dev/null || true
}
trap cleanup_qemu SIGTERM SIGINT

# Poll for VM readiness (rc.local prints marker when networking + PF are up)
BOOT_TIMEOUT=120
ELAPSED=0
echo "Waiting for OpenBSD VM to finish booting (timeout: ${BOOT_TIMEOUT}s)..."
while [ "$ELAPSED" -lt "$BOOT_TIMEOUT" ]; do
    # Check if QEMU crashed
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "ERROR: QEMU process exited unexpectedly"
        exit 1
    fi
    # Check for readiness marker
    if grep -q "rc.local: Network configuration complete." /tmp/console.log 2>/dev/null; then
        echo "OpenBSD VM is ready (boot time: ${ELAPSED}s)"
        touch /tmp/healthy
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
    echo "ERROR: OpenBSD VM did not become ready within ${BOOT_TIMEOUT}s"
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    exit 1
fi

# Keep container alive until QEMU exits
wait "$QEMU_PID"
