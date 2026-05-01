# Linxr QEMU Execution Process - Complete Technical Breakdown

## Architecture Overview

```
Flutter UI (Dart)
    ↓ Platform Channel
Kotlin Native Code (VmManager)
    ↓ ProcessBuilder
libqemu.so (QEMU Binary)
    ↓ SLIRP Networking
Debian Linux VM
```

---

## Step-by-Step Execution Process

### 1. **App Launch** (Flutter Layer)
**File**: `lib/main.dart`

- Flutter app starts
- `VmState` provider initialized (manages VM state across app)
- UI renders with Home, Terminal, and About tabs

---

### 2. **User Starts VM** (Dart → Kotlin Bridge)
**File**: `lib/services/vm_platform.dart`

```dart
static const platform = MethodChannel('com.ahk.linxv/vm');

Future<void> startVm() async {
  await platform.invokeMethod('startVm');
  _state = VmState.running;
}
```

- User taps "Start VM" button
- Flutter calls Kotlin via MethodChannel
- Bridge: `com.ahk.linxv/vm` channel

---

### 3. **Kotlin Receives Start Command** (Native Layer)
**File**: `android/app/src/main/kotlin/com/ahk/linxv/MainActivity.kt`

- MethodChannel handler receives "startVm" call
- Calls `vmManager.startVm()`
- Starts foreground service to keep VM alive

---

### 4. **VmManager.startVm()** - Core Orchestration

#### Step 4.1: Check Assets
```kotlin
val freshExtraction = !assetsReady()
if (freshExtraction) {
    extractAssets()
}
```

**What happens**:
- Checks if `assets_extracted.v5` marker file exists
- If not, extracts VM files from APK assets

#### Step 4.2: Extract Assets
```kotlin
private fun extractAssets() {
    vmDir.mkdirs()  // /data/data/com.ahk.linxv/files/vm/
    
    // Extract base.qcow2 (compressed Debian image)
    extractAndDecompress("vm/base.qcow2.gz", baseQcow2)
    
    // Extract kernel and initrd
    extractAsset("vm/vmlinuz-virt", File(vmDir, "vmlinuz-virt"))
    extractAsset("vm/initramfs-virt", File(vmDir, "initramfs-virt"))
}
```

**Files extracted to** `/data/data/com.ahk.linxv/files/vm/`:
- `base.qcow2` - Debian Trixie root filesystem (decompressed from .gz)
- `vmlinuz-virt` - Linux kernel 6.12.73
- `initramfs-virt` - Initial RAM filesystem

#### Step 4.3: Prepare User Image
```kotlin
val baseImage = File(vmDir, "base.qcow2")
val userImage = File(vmDir, "user.qcow2")

if (freshExtraction || !userImage.exists()) {
    baseImage.copyTo(userImage, overwrite = true)
}
```

**Why copy?**:
- `base.qcow2` = Read-only template
- `user.qcow2` = Writable copy (preserves user changes)
- Full copy (not overlay) for Debian compatibility

#### Step 4.4: Resolve QEMU Binary
```kotlin
private fun resolveQemuBinary(): File {
    val bin = File(nativeLibDir, "libqemu.so")
    return bin
}
```

**Path**: `/data/app/.../com.ahk.linxv-.../lib/arm64/libqemu.so`

**What is libqemu.so?**:
- QEMU compiled as Android shared library
- Actually a full QEMU binary (qemu-system-aarch64)
- Packaged as `.so` for Android compatibility
- Has `exec_type` SELinux label (executable on Android 10+)

#### Step 4.5: Build QEMU Command
```kotlin
private fun buildQemuCommand(...): List<String> {
    val cmd = mutableListOf<String>()
    cmd += qemuBin  // /data/app/.../lib/arm64/libqemu.so
    
    // Machine configuration
    cmd += listOf("-machine", "virt")
    cmd += listOf("-cpu", "cortex-a57")
    cmd += listOf("-smp", "2")        // 2 CPU cores
    cmd += listOf("-m", "1024")       // 1GB RAM
    
    // Disk
    cmd += listOf("-drive", "if=none,file=$userImage,id=user,format=qcow2")
    cmd += listOf("-device", "virtio-blk-pci,drive=user")
    
    // Network (SLIRP user-mode)
    cmd += listOf("-netdev", "user,id=net0,hostfwd=tcp::2222-:22,dns=1.1.1.1")
    cmd += listOf("-device", "virtio-net-pci,netdev=net0,romfile=")
    
    // Display
    cmd += listOf("-display", "none")
    cmd += listOf("-serial", "stdio")
    
    // Boot
    cmd += listOf("-kernel", "/data/.../vmlinuz-virt")
    cmd += listOf("-initrd", "/data/.../initramfs-virt")
    cmd += listOf("-append", "console=ttyAMA0 root=/dev/vda rw net.ifnames=0")
    
    return cmd
}
```

**Final command**:
```bash
/data/app/.../lib/arm64/libqemu.so \
  -machine virt \
  -cpu cortex-a57 \
  -smp 2 \
  -m 1024 \
  -drive if=none,file=/data/data/com.ahk.linxv/files/vm/user.qcow2,id=user,format=qcow2 \
  -device virtio-blk-pci,drive=user \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,dns=1.1.1.1 \
  -device virtio-net-pci,netdev=net0,romfile= \
  -display none \
  -serial stdio \
  -kernel /data/data/com.ahk.linxv/files/vm/vmlinuz-virt \
  -initrd /data/data/com.ahk.linxv/files/vm/initramfs-virt \
  -append "console=ttyAMA0 root=/dev/vda rw net.ifnames=0"
```

#### Step 4.6: Launch QEMU Process
```kotlin
vmProcess = ProcessBuilder(cmd).apply {
    environment()["LD_LIBRARY_PATH"] = nativeLibDir.absolutePath
    redirectErrorStream(true)
}.start()

isRunning = true
```

**What happens**:
- `ProcessBuilder` creates new process
- `LD_LIBRARY_PATH` set to `/data/app/.../lib/arm64/` (for QEMU dependencies)
- Process starts, QEMU begins execution

---

### 5. **QEMU Execution** (Native Binary)

#### Libraries Used
**Location**: `/data/app/.../lib/arm64/`

**Core QEMU libraries**:
- `libqemu.so` - Main QEMU binary (31MB)
- `libpixman-1.so` - Pixel manipulation library
- `libglib-2.0.so` - GLib utilities
- `libgio-2.0.so` - GIO I/O library
- `libfdt.so` - Flattened Device Tree library
- `libffi.so` - Foreign Function Interface
- `libcrypto.so` - OpenSSL crypto
- `libcurl.so` - HTTP client
- `libevent-2.1.so` - Event notification
- `libz.so` - Compression
- `libpng.so` - PNG support

**How Android executes .so as binary**:
1. Android linker (`/system/bin/linker64`) loads libqemu.so
2. Resolves dependencies from `LD_LIBRARY_PATH`
3. Executes entry point (QEMU main function)
4. QEMU runs as normal Linux process

---

### 6. **VM Boot Process** (Inside QEMU)

#### Boot Sequence:
1. **QEMU initializes**:
   - Creates ARM64 virtual machine (`-machine virt`)
   - Allocates 1GB RAM (`-m 1024`)
   - Sets up 2 virtual CPUs (`-smp 2`)

2. **Loads kernel**:
   - Reads `vmlinuz-virt` into memory
   - Loads `initramfs-virt` as initial root filesystem

3. **Kernel boots**:
   - Linux 6.12.73 starts
   - Mounts initramfs
   - Runs init scripts

4. **Root filesystem mounted**:
   - Kernel finds `/dev/vda` (virtio-blk device)
   - Mounts `user.qcow2` as root filesystem
   - Switches from initramfs to real root

5. **Systemd starts**:
   - PID 1: systemd
   - Starts services: SSH, networking, etc.

6. **Network configured**:
   - DHCP on eth0
   - Gets IP: 10.0.2.15
   - Gateway: 10.0.2.2 (QEMU SLIRP)
   - DNS: 10.0.2.3 (QEMU SLIRP DNS)

7. **SSH ready**:
   - OpenSSH listens on port 22 (inside VM)
   - QEMU forwards host:2222 → VM:22
   - Ready for connections

---

### 7. **Foreground Service** (Keeps VM Alive)
**File**: `android/app/src/main/kotlin/com/ahk/linxv/VmService.kt`

**Purpose**:
- Prevents Android from killing QEMU process
- Shows persistent notification
- Keeps VM running in background

---

### 8. **SSH Connection** (Terminal Tab)
**File**: `lib/screens/terminal_screen.dart`

**Flow**:
1. Flutter SSH client connects to `localhost:2222`
2. Android forwards to QEMU process
3. QEMU SLIRP forwards to VM port 22
4. OpenSSH in VM handles authentication
5. Terminal session established

---

## Network Architecture

```
Android App (localhost:2222)
    ↓
QEMU Process (port forwarding)
    ↓
SLIRP Network Stack (10.0.2.2)
    ↓
VM eth0 (10.0.2.15:22)
    ↓
OpenSSH Server
```

**SLIRP Features**:
- User-mode networking (no root required)
- NAT for outbound connections
- Port forwarding: 2222→22
- Built-in DHCP server
- Built-in DNS forwarder (10.0.2.3)

---

## File System Layout

### APK Assets (Compressed)
```
android/app/src/main/assets/
├── vm/
│   ├── base.qcow2.gz       (50MB compressed)
│   ├── vmlinuz-virt        (31MB)
│   └── initramfs-virt      (34MB)
```

### Native Libraries (Bundled in APK)
```
android/app/src/main/jniLibs/arm64-v8a/
├── libqemu.so              (31MB - QEMU binary)
├── libqemu_img.so          (qemu-img tool)
├── libpixman-1.so
├── libglib-2.0.so
└── [50+ dependency libraries]
```

### Runtime Files (Extracted on Device)
```
/data/data/com.ahk.linxv/files/
├── vm/
│   ├── base.qcow2          (Debian template, read-only)
│   ├── user.qcow2          (User's writable copy)
│   ├── vmlinuz-virt        (Kernel)
│   └── initramfs-virt      (Initrd)
└── assets_extracted.v5     (Version marker)
```

---

## Key Technical Details

### Why .so instead of executable?
- Android doesn't allow executables in APK
- Shared libraries (.so) are allowed
- QEMU compiled as shared library with main() entry point
- Android linker executes it like a binary

### Why external kernel/initrd?
- QEMU `-kernel` boot is faster than BIOS boot
- Direct kernel loading (no bootloader needed)
- Smaller image size (no /boot in qcow2)
- Better control over boot parameters

### Why copy base.qcow2 to user.qcow2?
- Debian needs writable root filesystem
- QEMU overlay images can be fragile
- Full copy ensures data persistence
- User changes saved in user.qcow2

### Why SLIRP networking?
- No root required (unlike TAP/TUN)
- Works on all Android devices
- Built into QEMU
- Automatic NAT and port forwarding

---

## Performance Characteristics

- **Boot time**: ~20-30 seconds
- **RAM usage**: 1GB (VM) + 200MB (QEMU) + 100MB (App)
- **CPU**: 2 virtual cores (maps to host cores)
- **Disk I/O**: virtio-blk (fast paravirtualized)
- **Network**: SLIRP (slower than TAP, but no root needed)

---

## Summary

Linxr runs a full Debian Linux VM on Android by:
1. Packaging QEMU as Android library (libqemu.so)
2. Bundling Debian image + kernel in APK assets
3. Extracting to app private storage on first run
4. Launching QEMU via ProcessBuilder
5. Using SLIRP for networking (no root)
6. Forwarding SSH port 2222→22
7. Keeping alive with foreground service
8. Connecting via Flutter SSH client

**No root, no containers, pure QEMU virtualization.**
