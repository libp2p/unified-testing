#!/bin/bash

# Load necessary kernel modules
modprobe nbd
modprobe ufs
modprobe tun  # For taps

# Assume two interfaces: eth0 and eth1 (Docker attaches them in order)
IF1=eth0
IF2=eth1

# Extract config for IF1
IP1=$(ip -4 addr show $IF1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
MASK1_CIDR=$(ip -4 addr show $IF1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\K\d+')
GW1=$(ip route show dev $IF1 | grep default | awk '{print $3}' || echo none)

# Extract config for IF2 (no GW assumed for secondary/LAN side)
IP2=$(ip -4 addr show $IF2 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
MASK2_CIDR=$(ip -4 addr show $IF2 | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\K\d+')
GW2=none

# Convert CIDR to netmask (quad format for OpenBSD hostname.if)
cidr_to_mask() {
  local cidr=$1
  local mask=$((0xffffffff << (32 - cidr)))
  echo $((mask >> 24 & 255)).$((mask >> 16 & 255)).$((mask >> 8 & 255)).$((mask & 255))
}
MASK1=$(cidr_to_mask $MASK1_CIDR)
MASK2=$(cidr_to_mask $MASK2_CIDR)

# Setup bridge and tap for IF1
ip addr flush dev $IF1
ip link set $IF1 up
brctl addbr br0
brctl addif br0 $IF1
ip tuntap add tap0 mode tap
ip link set tap0 up
brctl addif br0 tap0
ip link set br0 up

# Setup bridge and tap for IF2
ip addr flush dev $IF2
ip link set $IF2 up
brctl addbr br1
brctl addif br1 $IF2
ip tuntap add tap1 mode tap
ip link set tap1 up
brctl addif br1 tap1
ip link set br1 up

# Mount qcow2 via NBD, then mount OpenBSD root (assuming /dev/nbd0a is root)
qemu-nbd --connect=/dev/nbd0 /hdd.qcow2
mkdir /mnt_openbsd
mount -t ufs -o ufstype=openbsd,rw /dev/nbd0a /mnt_openbsd

# Configure OpenBSD network interfaces (vio0 and vio1)
echo "inet $IP1 $MASK1 $GW1" > /mnt_openbsd/etc/hostname.vio0
echo "inet $IP2 $MASK2 $GW2" > /mnt_openbsd/etc/hostname.vio1

# Set default gateway if present
if [ "$GW1" != "none" ]; then
  echo "$GW1" > /mnt_openbsd/etc/mygate
fi

# Enable IP forwarding for routing
echo "net.inet.ip.forwarding=1" >> /mnt_openbsd/etc/sysctl.conf

# Unmount and disconnect NBD
umount /mnt_openbsd
qemu-nbd --disconnect /dev/nbd0

# Run QEMU with installed HDD, two NICs bridged to container networks, serial console
exec qemu-system-x86_64 \
    -m 512M \
    -drive file=/hdd.qcow2,if=virtio,format=qcow2 \
    -netdev tap,id=net0,ifname=tap0,script=no \
    -device virtio-net-pci,netdev=net0 \
    -netdev tap,id=net1,ifname=tap1,script=no \
    -device virtio-net-pci,netdev=net1 \
    -nographic \
    -serial mon:stdio
