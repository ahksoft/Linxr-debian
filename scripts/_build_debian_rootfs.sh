#!/bin/bash
# Downloads pre-built Debian ARM64 qcow2 from DebianOnQEMU project
set -e

OUT_DIR=/out
RELEASE_URL="https://github.com/wtdcode/DebianOnQEMU/releases/download/v2024.01.05"

echo "--- Installing tools ---"
apt-get update
apt-get install -y wget qemu-utils libguestfs-tools

echo "--- Downloading Debian Bullseye ARM64 ---"
cd /tmp
wget -q --show-progress ${RELEASE_URL}/debian-bullseye-arm64.qcow2
wget -q --show-progress ${RELEASE_URL}/vmlinuz-5.10.0-26-arm64
wget -q --show-progress ${RELEASE_URL}/initrd.img-5.10.0-26-arm64

echo "--- Customizing Debian image ---"
# Set root password to 'debian'
# Configure networking and SSH for Debian
virt-customize -a debian-bullseye-arm64.qcow2 \
  --root-password password:debian \
  --hostname linxr-debian \
  --run-command 'systemctl enable ssh' \
  --run-command 'systemctl enable systemd-networkd' \
  --run-command 'mkdir -p /etc/systemd/network' \
  --write '/etc/systemd/network/20-wired.network:[Match]
Name=en*

[Network]
DHCP=yes' \
  --run-command 'sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config' \
  --run-command 'sed -i "s/#PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config' \
  2>/dev/null || echo "virt-customize not available, using as-is"

echo "--- Compressing qcow2 ---"
qemu-img convert -f qcow2 -O qcow2 -c debian-bullseye-arm64.qcow2 ${OUT_DIR}/base.qcow2
gzip -9 -c ${OUT_DIR}/base.qcow2 > ${OUT_DIR}/base.qcow2.gz
rm ${OUT_DIR}/base.qcow2

echo "--- Copying kernel and initrd ---"
cp vmlinuz-5.10.0-26-arm64 ${OUT_DIR}/vmlinuz-virt
cp initrd.img-5.10.0-26-arm64 ${OUT_DIR}/initramfs-virt

echo "--- Build complete ---"
ls -lh ${OUT_DIR}/
echo "Done."
