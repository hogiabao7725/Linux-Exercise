# BORE Kernel 6.12.63 Build Guide for Ubuntu

Complete step-by-step guide to compile and install BORE Kernel on Ubuntu.

---

## System Requirements

- **OS**: Ubuntu
- **RAM**: 24GB RAM
- **Disk**: 60GB free space
- **Time**: 45-60 minutes for compilation

---

## PHASE 1: PREPARE DEPENDENCIES

**Location**: Open Terminal (default at `~`)

```bash
# Update system
sudo apt update

# Install build tools
sudo apt install -y build-essential flex bison libssl-dev libelf-dev bc dwarves git fakeroot ccache libncurses-dev ncurses-term zstd

# Get kernel dependencies
sudo apt build-dep linux-image-unsigned-$(uname -r)
```

---

## PHASE 2: DOWNLOAD AND EXTRACT

**Location**: `~/kernel-build`

```bash
# Create working directory
mkdir -p ~/kernel-build && cd ~/kernel-build

# Download kernel source
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.63.tar.xz

# Download BORE patch (compatible with 6.12.63)
wget https://github.com/firelzrd/bore-scheduler/raw/main/patches/stable/linux-6.12-bore/0001-linux6.12.37-bore-6.5.9.patch

# Extract kernel
tar -xvf linux-6.12.63.tar.xz
```

---

## PHASE 3: PATCH AND CONFIGURE

**Location**: MUST enter `~/kernel-build/linux-6.12.63`

```bash
cd ~/kernel-build/linux-6.12.63

# Apply BORE patch
patch -p1 < ../0001-linux6.12.37-bore-6.5.9.patch

# Copy current system config
cp /boot/config-$(uname -r) .config

# Update config (press Enter if prompted)
make olddefconfig

# Disable certificate verification (prevents build errors)
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS
scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""

# Set custom kernel name
scripts/config --set-str LOCALVERSION "-bore-ubuntu"
```

---

## PHASE 4: COMPILE

**Location**: Stay at `~/kernel-build/linux-6.12.63`

```bash
# Compile with LTO optimization
make -j$(nproc) bindeb-pkg LTO=thin
```

⏱️ **Expected time**: 45-60 minutes (wait until prompt returns)

---

## PHASE 5: INSTALL AND ACTIVATE

**Location**: Go back to `~/kernel-build`

```bash
cd ..

# Install kernel packages
sudo dpkg -i linux-image-6.12.63-bore-ubuntu*.deb linux-headers-6.12.63-bore-ubuntu*.deb

# Update boot configuration
sudo update-initramfs -u -k all
sudo update-grub

# Verify installation
ls /boot/ | grep bore

# Reboot system
sudo reboot
```

---

## PHASE 6: VERIFY INSTALLATION

After reboot, open Terminal and run:

```bash
# Check kernel version (should show -bore-ubuntu)
uname -r

# Verify BORE is active
dmesg | grep -i bore
```

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Patch fails | Verify patch file is in correct location |
| Build error: certificate | Ensure Phase 3 config steps completed |
| Grub not updating | Run `sudo update-grub` again |
| Boot fails | Boot from previous kernel in Grub menu |

---

## Reference

- [BORE Scheduler Repository](https://github.com/firelzrd/bore-scheduler)
- [Linux Kernel Archives](https://kernel.org)
- [Ubuntu Kernel Build Guide](https://wiki.ubuntu.com/Kernel/BuildYourOwnKernel)
