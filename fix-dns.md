# DNS Fix for Linxr

QEMU SLIRP DNS doesn't work on Android. Workaround:

Inside VM, create persistent resolv.conf:
```bash
# Make resolv.conf immutable
chattr -i /etc/resolv.conf 2>/dev/null
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf
```

This prevents systemd-resolved from overwriting it.
