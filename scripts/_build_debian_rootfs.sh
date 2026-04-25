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

echo "--- Customizing Debian image ---"
# Set root password to 'debian'
virt-customize -a debian-bullseye-arm64.qcow2 \
  --root-password password:debian \
  --run-command 'systemctl enable ssh' \
  --hostname linxr-debian 2>/dev/null || echo "virt-customize not available, using as-is"

echo "--- Compressing qcow2 ---"
qemu-img convert -f qcow2 -O qcow2 -c debian-bullseye-arm64.qcow2 ${OUT_DIR}/base.qcow2
gzip -9 -c ${OUT_DIR}/base.qcow2 > ${OUT_DIR}/base.qcow2.gz
rm ${OUT_DIR}/base.qcow2

echo "--- Build complete ---"
ls -lh ${OUT_DIR}/
echo "Done."
