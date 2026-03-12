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

# Download OpenBSD sets to local mirror directory
# The installer fetches from http://10.0.2.2/pub/OpenBSD/7.8/amd64/
RUN mkdir -p /tftp/pub/OpenBSD/7.8/amd64 && \
    cd /tftp/pub/OpenBSD/7.8/amd64 && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/base78.tgz && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/comp78.tgz && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/man78.tgz && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/bsd && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/bsd.mp && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/bsd.rd && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/SHA256 && \
    wget https://cdn.openbsd.org/pub/OpenBSD/7.8/amd64/BUILDINFO

# Create /etc/ directory for boot.conf
RUN mkdir -p /tftp/etc

# Copy the boot.conf
COPY boot.conf /tftp/etc/boot.conf

# Copy random.seed
COPY random.seed /tftp/etc/random.seed

# Copy autoinstall file (assumes it's in build context)
COPY install.conf /tftp/install.conf

# Build site78.tgz with config files baked in (extracted to / on target)
# and install.site for dynamic post-install tasks.
# Including files directly in the tarball is more robust than relying solely
# on install.site heredocs — set extraction is bulletproof; script execution
# requires the file to be marked executable and can fail silently.
RUN mkdir -p /tmp/site/etc
COPY pf.conf /tmp/site/etc/pf.conf
COPY rc.local /tmp/site/etc/rc.local
COPY rc.conf.local /tmp/site/etc/rc.conf.local
COPY install.site /tmp/site/install.site
RUN chmod +x /tmp/site/install.site /tmp/site/etc/rc.local && \
    touch /tmp/site/etc/firstboot_halt && \
    cd /tmp/site && tar -czf /tftp/pub/OpenBSD/7.8/amd64/site78.tgz . && \
    cd /tftp/pub/OpenBSD/7.8/amd64 && \
    printf 'SHA256 (%s) = %s\n' site78.tgz "$(sha256sum site78.tgz | cut -d' ' -f1)" >> SHA256 && \
    ls -l > index.txt

# Create 4GB qcow2 virtual HDD
RUN qemu-img create -f qcow2 /disks/hdd.qcow2 4G

# Run QEMU to netboot and install (unattended via auto_install.conf on disk)
# - Uses user networking with built-in TFTP for PXE
# - Boots from network, attaches HDD as vd0 (virtio)
# - Python HTTP server serves sets from /tftp (accessible at http://10.0.2.2/)
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

# Second boot: consume rc.firsttime (SSH key generation, ldconfig, sysmerge, etc.)
# so runtime boots are fast. The install.site sentinel (/etc/firstboot_halt) causes
# rc.local to halt -p after rc.firsttime completes. -no-reboot makes QEMU exit on halt.
RUN qemu-system-x86_64 \
    -m 1G \
    -nic none \
    -drive file=/disks/hdd.qcow2,if=virtio,format=qcow2,cache=none,discard=unmap \
    -nographic \
    -serial mon:stdio \
    -monitor null \
    -no-reboot

# Stage 2: Final image - run QEMU with installed OpenBSD
FROM debian:13-slim

# Install runtime dependencies for QEMU, bridging, and ISO generation
RUN apt-get update && apt-get install -y --no-install-recommends \
    qemu-system-x86 qemu-utils bridge-utils iproute2 genisoimage \
    && rm -rf /var/lib/apt/lists/*

# Copy installed HDD from installer stage
COPY --from=installer /disks/hdd.qcow2 /hdd.qcow2

# Entrypoint script to setup bridges/taps, configure OpenBSD networking, and run QEMU
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=2s --timeout=2s --start-period=120s --retries=1 \
    CMD test -f /tmp/healthy

ENTRYPOINT ["/entrypoint.sh"]
