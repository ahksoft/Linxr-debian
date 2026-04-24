#!/bin/bash
# Builds Debian ARM64 qcow2 with automated installation
set -e

OUT_DIR=/out
IMAGE_SIZE=3G
DEBIAN_RELEASE=bookworm

echo "--- Installing build tools ---"
apt-get update
apt-get install -y qemu-system-aarch64 qemu-utils wget libguestfs-tools

echo "--- Downloading Debian netboot installer ---"
mkdir -p /tmp/installer
cd /tmp/installer
wget -q http://ftp.debian.org/debian/dists/${DEBIAN_RELEASE}/main/installer-arm64/current/images/netboot/debian-installer/arm64/linux
wget -q http://ftp.debian.org/debian/dists/${DEBIAN_RELEASE}/main/installer-arm64/current/images/netboot/debian-installer/arm64/initrd.gz

echo "--- Creating preseed configuration ---"
cat > preseed.cfg <<'EOF'
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string linxr-debian
d-i netcfg/get_domain string localdomain
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i passwd/root-password password debian
d-i passwd/root-password-again password debian
d-i passwd/make-user boolean false
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string openssh-server sudo bash curl vim-tiny net-tools iputils-ping
d-i pkgsel/upgrade select full-upgrade
popularity-contest popularity-contest/participate boolean false
d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda
d-i finish-install/reboot_in_progress note
EOF

echo "--- Injecting preseed into initrd ---"
gunzip initrd.gz
echo preseed.cfg | cpio -o -H newc -A -F initrd
gzip initrd
mv initrd.gz initrd-preseed.gz

echo "--- Creating qcow2 image ---"
qemu-img create -f qcow2 ${OUT_DIR}/debian.qcow2 ${IMAGE_SIZE}

echo "--- Running automated Debian installation ---"
timeout 1800 qemu-system-aarch64 \
  -M virt -cpu cortex-a53 -m 1024 -nographic \
  -kernel linux \
  -initrd initrd-preseed.gz \
  -append "auto=true priority=critical console=ttyAMA0" \
  -drive if=virtio,file=${OUT_DIR}/debian.qcow2,format=qcow2 \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 || true

echo "--- Extracting kernel and initrd from installed image ---"
virt-ls -a ${OUT_DIR}/debian.qcow2 /boot/
KERNEL=$(virt-ls -a ${OUT_DIR}/debian.qcow2 /boot/ | grep '^vmlinuz-' | sort -V | tail -1)
INITRD=$(virt-ls -a ${OUT_DIR}/debian.qcow2 /boot/ | grep '^initrd.img-' | sort -V | tail -1)

echo "Extracting: $KERNEL and $INITRD"
virt-copy-out -a ${OUT_DIR}/debian.qcow2 /boot/$KERNEL /boot/$INITRD ${OUT_DIR}/

# Rename to generic names
mv ${OUT_DIR}/$KERNEL ${OUT_DIR}/vmlinuz-virt
mv ${OUT_DIR}/$INITRD ${OUT_DIR}/initramfs-virt

echo "--- Compressing qcow2 ---"
qemu-img convert -f qcow2 -O qcow2 -c ${OUT_DIR}/debian.qcow2 ${OUT_DIR}/base.qcow2
rm ${OUT_DIR}/debian.qcow2

gzip -9 -c ${OUT_DIR}/base.qcow2 > ${OUT_DIR}/base.qcow2.gz
rm ${OUT_DIR}/base.qcow2

echo "--- Build complete ---"
ls -lh ${OUT_DIR}/
echo "Done."
