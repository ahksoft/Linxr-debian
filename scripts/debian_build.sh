#!/usr/bin/env bash
# Minimal Debian ARM64 QEMU image builder
set -euo pipefail

# Config
SUITE="${SUITE:-bookworm}"
VIRTUAL_SIZE="${VIRTUAL_SIZE:-8G}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

BASE_PACKAGES=(
    systemd systemd-sysv udev dbus
    openssh-server sudo
    iproute2 iputils-ping ca-certificates
    linux-image-arm64
)

# Paths
OUT_DIR="/out"
ROOTFS="$(mktemp -d /tmp/deb-rootfs-XXXXX)"
MNT="$(mktemp -d /tmp/deb-mnt-XXXXX)"
RAW_IMG="/tmp/debian-arm64.raw"
QCOW2="${OUT_DIR}/base.qcow2"
KERNEL_OUT="${OUT_DIR}/vmlinuz-virt"
INITRD_OUT="${OUT_DIR}/initramfs-virt"

mkdir -p "$OUT_DIR"

log() { echo ""; echo "=== $* ==="; }

cleanup() {
    set +e
    for mp in proc sys dev/pts dev run; do
        mountpoint -q "$ROOTFS/$mp" 2>/dev/null && umount -lf "$ROOTFS/$mp"
    done
    mountpoint -q "$MNT" 2>/dev/null && umount -lf "$MNT"
    rm -f "$RAW_IMG"
    rm -rf "$ROOTFS" "$MNT"
}
trap cleanup EXIT

# Step 1: Debootstrap stage 1
log "[1/7] Debootstrap stage 1"
debootstrap \
    --arch=arm64 \
    --foreign \
    --variant=minbase \
    --include="$(IFS=,; echo "${BASE_PACKAGES[*]}")" \
    "$SUITE" \
    "$ROOTFS" \
    "$MIRROR"

# Step 2: Inject lean configs
log "[2/7] Injecting dpkg no-doc config"
mkdir -p "$ROOTFS/etc/dpkg/dpkg.cfg.d"
cat > "$ROOTFS/etc/dpkg/dpkg.cfg.d/01_nodoc" <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/locale.alias
EOF

mkdir -p "$ROOTFS/etc/apt/apt.conf.d"
cat > "$ROOTFS/etc/apt/apt.conf.d/99lean" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF

# Step 3: Debootstrap stage 2
log "[3/7] Debootstrap stage 2"
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t tmpfs tmpfs "$ROOTFS/run"

chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

# Step 4: Configure system
log "[4/7] Configuring system"

cat > "$ROOTFS/etc/fstab" <<EOF
/dev/vda  /  ext4  rw,relatime,errors=remount-ro  0  1
EOF

echo "linxr-debian" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   linxr-debian
EOF

mkdir -p "$ROOTFS/etc/systemd/network"
cat > "$ROOTFS/etc/systemd/network/10-eth.network" <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes
DNS=8.8.8.8
EOF

# Set root password with pre-hashed value (password: root)
chroot "$ROOTFS" usermod -p '\$6\$saltsalt\$qFmFH.bQmmtXzyBY0s9v7Oicd2z4XSIecDzlB5KiA2/jctKu9YterLp8wwnSq.qc.eoxqOqdPujpL6vG/0DG9/' root
chroot "$ROOTFS" passwd -u root

mkdir -p "$ROOTFS/run/sshd"
chroot "$ROOTFS" ssh-keygen -A 2>/dev/null || true

# Force SSH password authentication
cat > "$ROOTFS/etc/ssh/sshd_config.d/99-linxr.conf" <<EOF
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
EOF

chmod 644 "$ROOTFS/etc/ssh/sshd_config.d/99-linxr.conf"

echo "%sudo ALL=(ALL) NOPASSWD: ALL" > "$ROOTFS/etc/sudoers.d/nopasswd"
chmod 0440 "$ROOTFS/etc/sudoers.d/nopasswd"

chroot "$ROOTFS" systemctl enable ssh systemd-networkd systemd-resolved 2>/dev/null || true
chroot "$ROOTFS" systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# Step 5: Extract kernel/initrd, purge from rootfs
log "[5/7] Extracting kernel/initrd"
KERNEL=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | sort -V | tail -1)
INITRD=$(ls "$ROOTFS/boot/initrd.img-"* 2>/dev/null | sort -V | tail -1)

cp "$KERNEL" "$KERNEL_OUT"
cp "$INITRD" "$INITRD_OUT"

KVER=$(basename "$KERNEL" | sed 's/vmlinuz-//')
chroot "$ROOTFS" bash -c "
    dpkg --purge linux-image-arm64 linux-image-${KVER} 2>/dev/null || true
    rm -rf /boot/*
" 2>/dev/null || true

# Step 6: Cleanup
log "[6/7] Cleanup"
chroot "$ROOTFS" bash -c "
    rm -f /usr/bin/qemu-aarch64-static
    apt-get autoremove --purge -y 2>/dev/null || true
    apt-get clean
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*
    rm -rf /usr/share/{doc,man,info,locale}/*
    rm -rf /tmp/* /var/tmp/*
    find /var/log -type f -delete 2>/dev/null || true
" 2>/dev/null || true

for mp in proc sys dev/pts dev run; do
    umount -lf "$ROOTFS/$mp" || true
done

# Step 7: Create qcow2
log "[7/7] Building qcow2"
USED_KB=$(du -sk "$ROOTFS" | cut -f1)
RAW_MB=$(( (USED_KB * 120 / 100 / 1024) + 64 ))

truncate -s "${RAW_MB}M" "$RAW_IMG"
mkfs.ext4 -L rootfs -m 1 -F "$RAW_IMG"

mount -o loop "$RAW_IMG" "$MNT"
rsync -aHAX --numeric-ids \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
    --exclude='/run/*' --exclude='/tmp/*' \
    "$ROOTFS/" "$MNT/"

mkdir -p "$MNT"/{proc,sys,dev,run,tmp}
chmod 1777 "$MNT/tmp"
sync
umount "$MNT"

e2fsck -fy "$RAW_IMG" || true
resize2fs -M "$RAW_IMG"

qemu-img convert -f raw -O qcow2 -c -o compression_type=zlib "$RAW_IMG" "$QCOW2"
qemu-img resize "$QCOW2" "$VIRTUAL_SIZE"

gzip -9 -c "$QCOW2" > "${QCOW2}.gz"
rm "$QCOW2"

log "Build complete"
ls -lh "$OUT_DIR/"
