#!/bin/bash
# Builds Debian ARM64 rootfs as base.qcow2.gz
set -e

ROOTFS=/tmp/rootfs
IMAGE_SIZE=2G
DEBIAN_RELEASE=bookworm

echo "--- Installing build tools ---"
apt-get update
apt-get install -y debootstrap qemu-user-static e2fsprogs qemu-utils binfmt-support

echo "--- Bootstrapping Debian ${DEBIAN_RELEASE} ---"
debootstrap --arch=arm64 --variant=minbase --include=systemd-sysv,openssh-server,sudo,bash,linux-image-arm64,net-tools,iputils-ping,curl,vim-tiny ${DEBIAN_RELEASE} ${ROOTFS} http://deb.debian.org/debian

echo "--- Configuring Debian ---"
# Set root password
echo "root:debian" | chroot ${ROOTFS} chpasswd

# Configure SSH
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' ${ROOTFS}/etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' ${ROOTFS}/etc/ssh/sshd_config

# Enable SSH service
chroot ${ROOTFS} systemctl enable ssh

# Network configuration (systemd-networkd)
cat > ${ROOTFS}/etc/systemd/network/eth0.network <<'EOF'
[Match]
Name=eth0

[Network]
Address=10.0.2.15/24
Gateway=10.0.2.2
DNS=10.0.2.3
DNS=8.8.8.8
EOF

chroot ${ROOTFS} systemctl enable systemd-networkd
chroot ${ROOTFS} systemctl enable systemd-resolved

# Hostname
echo "linxr-debian" > ${ROOTFS}/etc/hostname

# fstab
cat > ${ROOTFS}/etc/fstab <<'EOF'
/dev/vda / ext4 defaults 0 1
tmpfs /tmp tmpfs defaults 0 0
EOF

# Serial console
chroot ${ROOTFS} systemctl enable serial-getty@ttyAMA0.service

# Clean up
chroot ${ROOTFS} apt-get clean
rm -rf ${ROOTFS}/var/lib/apt/lists/*

echo "--- Creating ${IMAGE_SIZE} ext4 image ---"
mke2fs -t ext4 -d ${ROOTFS} -L linxr-debian /out/base.ext4 ${IMAGE_SIZE}

echo "--- Converting to qcow2 ---"
qemu-img convert -f raw -O qcow2 -c /out/base.ext4 /out/base.qcow2
rm -f /out/base.ext4

echo "--- Compressing ---"
gzip -9 -c /out/base.qcow2 > /out/base.qcow2.gz
rm -f /out/base.qcow2

ls -lh /out/base.qcow2.gz
echo "Done."
