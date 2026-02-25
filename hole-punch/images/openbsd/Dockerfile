# Stage 1: Installer - netboot and install OpenBSD to virtual HDD
FROM debian:13-slim AS installer

# Install dependencies for download, disk prep, and QEMU
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates dosfstools qemu-system-x86 qemu-utils python3 \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir /tftp /disks

# Download OpenBSD 7.8 amd64 boot files for PXE (from a mirror)
WORKDIR /tftp
RUN wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/pxeboot && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/bsd.rd && \
    ln -s bsd.rd bsd && \
    ln -s pxeboot auto_install

# Create /etc/ directory for boot.conf
RUN mkdir -p /tftp/etc

# Copy the boot.conf
COPY boot.conf /tftp/etc/boot.conf

# Copy random.seed
COPY random.seed /tftp/etc/random.seed

# Copy autoinstall file (assumes it's in build context)
COPY install.conf /tftp/install.conf

# Create 2GB qcow2 virtual HDD
RUN qemu-img create -f qcow2 /disks/hdd.qcow2 4G

# Run QEMU to netboot and install (unattended via auto_install.conf on disk)
# - Uses user networking with built-in TFTP for PXE
# - Boots from network, attaches HDD as vd0 (virtio), conf.img as vd1
# - No graphics, serial to stdio; exits on reboot (install complete)
RUN (cd /tftp && python3 -m http.server 80 &) && sleep 2 && \
    qemu-system-x86_64 \
    -m 1G \
    -boot order=n,menu=off \
    -netdev user,id=net0,tftp=/tftp,bootfile=/auto_install \
    -device e1000,netdev=net0 \
    -drive file=/disks/hdd.qcow2,if=virtio,format=qcow2,cache=none,discard=unmap \
    -nographic \
    -serial mon:stdio \
    -monitor null \
    -no-reboot

# Stage 2: Final image - run QEMU with installed OpenBSD
FROM debian:13-slim

# Install runtime dependencies for QEMU, bridging, and mounting
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils bridge-utils iproute2 kmod \
    && rm -rf /var/lib/apt/lists/*

# Copy installed HDD from installer stage
COPY --from=installer /disks/hdd.qcow2 /hdd.qcow2

# Entrypoint script to setup bridges/taps, configure OpenBSD networking, and run QEMU
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
