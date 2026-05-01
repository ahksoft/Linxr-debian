#!/usr/bin/env bash
# Complete Debian ARM64 build with working DNS for Android QEMU
set -euo pipefail

SUITE="bookworm"
ARCH="arm64"
MIRROR="http://deb.debian.org/debian"
ROOTFS="/tmp/debian-rootfs"
OUT_DIR="/out"

mkdir -p "$OUT_DIR" "$ROOTFS"

log() { echo ""; echo "=== $* ==="; }

# Step 1: Debootstrap
log "[1/6] Debootstrap"
debootstrap --foreign --arch="$ARCH" --include=locales,ca-certificates "$SUITE" "$ROOTFS" "$MIRROR"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

# Step 2: Install packages
log "[2/6] Installing packages"
cat > "$ROOTFS/etc/fstab" <<EOF
/dev/vda / ext4 errors=remount-ro 0 1
EOF

chroot "$ROOTFS" apt update
chroot "$ROOTFS" apt install -y \
  linux-image-arm64 \
  initramfs-tools \
  openssh-server \
  sudo \
  dnsmasq \
  resolvconf \
  net-tools \
  iputils-ping \
  curl \
  wget

# Configure initramfs
sed -i 's/MODULES=most/MODULES=list/' "$ROOTFS/etc/initramfs-tools/initramfs.conf"
cat >> "$ROOTFS/etc/initramfs-tools/modules" <<EOF
virtio_mmio
virtio_blk
virtio_net
virtio_pci
ext4
EOF

chroot "$ROOTFS" update-initramfs -u

# Step 3: Configure DNS with dnsmasq
log "[3/6] Configuring DNS"

# Disable systemd-resolved
chroot "$ROOTFS" systemctl disable systemd-resolved || true
chroot "$ROOTFS" systemctl mask systemd-resolved || true

# Configure dnsmasq to use external DNS directly
cat > "$ROOTFS/etc/dnsmasq.conf" <<EOF
# Listen on localhost only
listen-address=127.0.0.1
bind-interfaces

# Use Google and Cloudflare DNS
server=8.8.8.8
server=8.8.4.4
server=1.1.1.1
server=1.0.0.1

# Cache settings
cache-size=1000
no-resolv
no-poll

# Don't read /etc/hosts
no-hosts
EOF

# Set resolv.conf to use local dnsmasq
cat > "$ROOTFS/etc/resolv.conf" <<EOF
nameserver 127.0.0.1
options timeout:2 attempts:3
EOF

# Make it immutable
chroot "$ROOTFS" chattr +i /etc/resolv.conf || true

# Enable dnsmasq
chroot "$ROOTFS" systemctl enable dnsmasq

# Step 4: Configure network
log "[4/6] Configuring network"
cat > "$ROOTFS/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
  dns-nameservers 127.0.0.1
EOF

# Step 5: Configure SSH and users
log "[5/6] Configuring SSH and users"
cat > "$ROOTFS/etc/ssh/sshd_config" <<EOF
Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

echo "linxr-debian" > "$ROOTFS/etc/hostname"
: > "$ROOTFS/etc/machine-id"

chroot "$ROOTFS" bash -c "adduser --disabled-password --gecos '' debian"
chroot "$ROOTFS" bash -c 'echo "root:root" | chpasswd'
chroot "$ROOTFS" bash -c 'echo "debian:debian" | chpasswd'

echo "debian ALL=(ALL:ALL) NOPASSWD: ALL" > "$ROOTFS/etc/sudoers.d/debian"
chmod 440 "$ROOTFS/etc/sudoers.d/debian"

# Step 6: Create image
log "[6/6] Creating qcow2"
KERNEL=$(ls "$ROOTFS/boot/vmlinuz-"* | sort -V | tail -1)
INITRD=$(ls "$ROOTFS/boot/initrd.img-"* | sort -V | tail -1)

cp "$KERNEL" "$OUT_DIR/vmlinuz-virt"
cp "$INITRD" "$OUT_DIR/initramfs-virt"

virt-make-fs --type=ext4 --size=8G "$ROOTFS" /tmp/raw.img
qemu-img convert -c -f raw -O qcow2 /tmp/raw.img "$OUT_DIR/base.qcow2"
gzip -9 "$OUT_DIR/base.qcow2"

log "Build complete"
ls -lh "$OUT_DIR/"
