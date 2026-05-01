#!/usr/bin/env bash
# Debian ARM64 QEMU image builder - based on working workflow
set -euo pipefail

# Config
SUITE="${SUITE:-trixie}"
ARCH="arm64"
MIRROR="http://deb.debian.org/debian"
HOSTNAME="linxr-debian"

# Paths
OUT_DIR="/out"
ROOTFS="$(mktemp -d /tmp/deb-rootfs-XXXXX)"
RAW_IMG="/tmp/debian-arm64.raw"
QCOW2="${OUT_DIR}/base.qcow2"

mkdir -p "$OUT_DIR"

log() { echo ""; echo "=== $* ==="; }

cleanup() {
    set +e
    umount -lf "$ROOTFS"/{proc,sys,dev/pts,dev} 2>/dev/null
    rm -f "$RAW_IMG"
    rm -rf "$ROOTFS"
}
trap cleanup EXIT

# Step 1: Debootstrap stage 1
log "[1/6] Debootstrap stage 1"
debootstrap --foreign --arch="$ARCH" --include=locales "$SUITE" "$ROOTFS" "$MIRROR"

# Step 2: Debootstrap stage 2
log "[2/6] Debootstrap stage 2"
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

# Step 3: Install kernel and essential packages
log "[3/6] Installing kernel and packages"
echo 'fake /usr ext4 fake 0 1' > "$ROOTFS/etc/fstab"

chroot "$ROOTFS" apt update
chroot "$ROOTFS" apt install -y initramfs-tools

# Configure initramfs for minimal size
sed -i 's/MODULES=most/MODULES=list/' "$ROOTFS/etc/initramfs-tools/initramfs.conf"

cat >> "$ROOTFS/etc/initramfs-tools/modules" <<EOF
virtio_mmio
virtio_blk
virtio_net
virtio_pci
ext4
sd_mod
EOF

# Install kernel and SSH
chroot "$ROOTFS" apt install -y linux-image-arm64 openssh-server sudo

# Update fstab
echo '/dev/vda / ext4 errors=remount-ro 0 1' > "$ROOTFS/etc/fstab"

# Step 4: Configure SSH
log "[4/6] Configuring SSH"
cat > "$ROOTFS/etc/ssh/sshd_config" <<EOF
Port 22
ListenAddress 0.0.0.0
ListenAddress ::
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

# Step 5: Configure system
log "[5/6] Configuring system"

# Network configuration using /etc/network/interfaces
cat >> "$ROOTFS/etc/network/interfaces" <<EOF

auto eth0
iface eth0 inet dhcp
EOF

# DNS configuration - use public DNS directly
cat > "$ROOTFS/etc/resolv.conf" <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

# Hostname
echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
: > "$ROOTFS/etc/machine-id"

# Create users
chroot "$ROOTFS" bash -c "adduser --disabled-password --gecos '' debian"
chroot "$ROOTFS" bash -c 'echo "root:root" | chpasswd'
chroot "$ROOTFS" bash -c 'echo "debian:debian" | chpasswd'

# Sudo for debian user
echo "debian ALL=(ALL:ALL) NOPASSWD: ALL" > "$ROOTFS/etc/sudoers.d/debian"
chmod 440 "$ROOTFS/etc/sudoers.d/debian"

# Step 6: Extract kernel/initrd and create qcow2
log "[6/6] Creating qcow2 image"

# Extract kernel and initrd
KERNEL=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "$ROOTFS/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)

cp "$KERNEL" "${OUT_DIR}/vmlinuz-virt"
cp "$INITRD" "${OUT_DIR}/initramfs-virt"

# Create qcow2
virt-make-fs --type=ext4 --size=8G "$ROOTFS" "$RAW_IMG"
qemu-img convert -c -f raw -O qcow2 "$RAW_IMG" "$QCOW2"

# Compress
gzip -9 "$QCOW2"

log "Build complete"
ls -lh "$OUT_DIR/"
