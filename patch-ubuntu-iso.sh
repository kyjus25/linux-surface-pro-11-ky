#!/usr/bin/env bash
#
# patch-ubuntu-iso.sh
#
# Takes the Ubuntu Concept "Resolute" ARM64 ISO for Snapdragon X Elite and
# patches in ath12k WiFi changes needed for the Surface Pro 11 (and similar
# WCN7850-based devices where rfkill is hard-blocked).
#
# Everything runs inside a single Docker container on non-aarch64 hosts,
# so the only requirement is Docker.
#
# Patches applied:
#   2. ath12k: always skip rfkill (modified — original checked devicetree)
#   4. ath12k: allow setting MAC address via devicetree
#
# Patches 1 and 3 (dt-bindings/DTS) are skipped — UEFI ARM64 firmware
# provides the devicetree, so there are no DTBs to patch in the ISO.
#
# Usage:
#   ./patch-ubuntu-iso.sh [--local-iso /path/to/resolute.iso]
#
#   --local-iso  Path to a pre-downloaded ISO (skips download)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ISO_FILE="$BUILD_DIR/resolute-desktop-arm64+x1e.iso"
OUTPUT_ISO="$BUILD_DIR/resolute-desktop-arm64+x1e-wifi-patched.iso"
ISO_URL="https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso"

info()  { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }

mkdir -p "$BUILD_DIR"
rm -f "$OUTPUT_ISO" "$BUILD_DIR/Dockerfile.builder" "$BUILD_DIR/patch-inner.sh"

# Parse flags
LOCAL_ISO=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-iso) LOCAL_ISO="$2"; shift 2 ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# -- Step 1: Get the ISO ---------------------------------------------------
if [ -n "$LOCAL_ISO" ]; then
    if [ ! -f "$LOCAL_ISO" ]; then
        echo "Local ISO not found: $LOCAL_ISO"
        exit 1
    fi
    mkdir -p "$BUILD_DIR"
    cp "$LOCAL_ISO" "$ISO_FILE"
elif [ ! -f "$ISO_FILE" ]; then
    info "Downloading ISO ..."
    mkdir -p "$BUILD_DIR"
    if command -v wget &>/dev/null; then
        wget --progress=dot:giga -O "$ISO_FILE" "$ISO_URL"
    elif command -v curl &>/dev/null; then
        curl -L -o "$ISO_FILE" "$ISO_URL"
    else
        echo "Need wget or curl to download the ISO"
        exit 1
    fi
else
    info "ISO already present at $ISO_FILE"
fi

# -- Step 2: Build the Docker image with all tools -------------------------
info "Building Docker builder image (one-time setup)..."

cat > "$BUILD_DIR/Dockerfile.builder" <<-'DOCKER_EOF'
	FROM arm64v8/ubuntu:26.04

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git ca-certificates make gcc flex bison bc libssl-dev libelf-dev dwarves cpio \
    python3 rsync wget xz-utils zstd xorriso squashfs-tools binutils kmod mtools \
    && rm -rf /var/lib/apt/lists/*

	WORKDIR /work
	DOCKER_EOF

docker build -t sp11-iso-patcher -f "$BUILD_DIR/Dockerfile.builder" "$BUILD_DIR" > /dev/null

# -- Step 3: Run everything inside the container ---------------------------
info "Running patcher inside Docker container..."

cat > "$BUILD_DIR/patch-inner.sh" <<-'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }

ISO="/build/resolute-desktop-arm64+x1e.iso"
PATCHES_DIR="/build/patches"
WORK="/work"
OUTPUT_ISO="/build/resolute-desktop-arm64+x1e-wifi-patched.iso"
GRUB_CFG="$WORK/iso/boot/grub/grub.cfg"
EFI_BOOT="$WORK/iso/EFI/boot"

# 1. Extract ISO
info "Extracting ISO ..."
mkdir -p "$WORK/iso"
xorriso -osirrox on -indev "$ISO" -extract / "$WORK/iso" &>/dev/null
chmod -R u+w "$WORK/iso"

# 2. Find root filesystem image
info "Searching for rootfs image in ISO ..."
find "$WORK/iso" -maxdepth 5 -type f \( -name "*.squashfs" -o -name "*.img" -o -name "*.rootfs" -o -name "*.cpio" \) 2>/dev/null

SQUASH=$(find "$WORK/iso" -maxdepth 5 -type f -name "minimal.squashfs" ! -name "minimal.*.squashfs" 2>/dev/null | head -1 || true)
if [ -z "$SQUASH" ]; then
    SQUASH=$(find "$WORK/iso" -maxdepth 5 -type f \( -name "*.squashfs" -o -name "filesystem.img" -o -name "root.img" \) 2>/dev/null | head -1 || true)
fi
if [ -z "$SQUASH" ]; then
    echo "No squashfs or filesystem image found."
    echo "Full ISO file tree:"
    find "$WORK/iso" -type f | head -80
    exit 1
fi
info "Found: $SQUASH"

info "Unsquashing rootfs ..."
mkdir -p "$WORK/rootfs"
unsquashfs -f -d "$WORK/rootfs" "$SQUASH" &>/dev/null

# 3. Detect kernel version
KVER=$(find "$WORK/rootfs/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 | xargs basename || true)
if [ -z "$KVER" ]; then
    echo "Could not detect kernel version from /lib/modules"
    exit 1
fi
info "Detected kernel version: $KVER"

# 4. Extract kernel config
CONFIG_SRC=$(find "$WORK/rootfs/boot" -name "config-*" 2>/dev/null | head -1 || true)
if [ -z "$CONFIG_SRC" ]; then
    CONFIG_SRC=$(find "$WORK/rootfs/lib/modules" -name "config" 2>/dev/null | head -1 || true)
fi

if [ -n "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" "$WORK/kernel-config"
    info "Extracted kernel config from $CONFIG_SRC"
else
    echo "Could not find kernel config; falling back to defconfig"
    touch "$WORK/kernel-config"
fi

# 5. Apply Goldilocks Maneuver (EFI Shim bypass + boot fixes)
info "Applying Goldilocks Maneuver ..."

# 5a. Replace shim with full GRUB in the ISO tree (for -e flag below)
if [ -f "$EFI_BOOT/bootaa64.efi" ] && [ -f "$EFI_BOOT/grubaa64.efi" ]; then
    cp "$EFI_BOOT/grubaa64.efi" "$EFI_BOOT/bootaa64.efi"
    info "  Promoted grubaa64.efi -> bootaa64.efi (ISO tree)"
fi

# 5b. Modify kernel cmdline in grub.cfg
if [ -f "$GRUB_CFG" ]; then
    sed -i 's/cmdline="clk_ignore_unused pd_ignore_unused arm64.nopauth"/cmdline="efi=novamap clk_ignore_unused pd_ignore_unused arm64.nopauth module_blacklist=snd_sof_qcom_x1e,snd_soc_qcom_common,qc_adsp_pas"/' "$GRUB_CFG"
    info "  Updated grub.cfg with efi=novamap + audio blacklist"
fi

# 5c. Extract the hidden EFI boot image from the original ISO and patch it
xorriso -osirrox on -indev "$ISO" -extract_boot_images /tmp/ 2>/dev/null
EFI_IMG="/tmp/eltorito_img1_uefi.img"
if [ -f "$EFI_IMG" ] && command -v mcopy &>/dev/null; then
    # Delete both bootaa64.efi AND grubaa64.efi to free enough space for the larger GRUB
    mdel -i "$EFI_IMG" ::/EFI/boot/bootaa64.efi ::/EFI/boot/grubaa64.efi 2>/dev/null || true
    mcopy -i "$EFI_IMG" "$WORK/iso/EFI/boot/grubaa64.efi" ::/EFI/boot/bootaa64.efi 2>/dev/null
    info "  Patched hidden EFI boot image (shim -> GRUB)"
fi
if [ -f "$EFI_IMG" ]; then
    cp "$EFI_IMG" "$WORK/iso/boot/grub/efi.img"
fi

# 6. Locate kernel build tree from rootfs
info "Using kernel build tree from rootfs ..."
KERNEL_BUILD="$WORK/rootfs/usr/src/linux-headers-7.0.0-22-qcom-x1e"

if [ ! -d "$KERNEL_BUILD" ]; then
    echo "Kernel build tree not found at $KERNEL_BUILD"
    exit 1
fi
info "Kernel build tree: $KERNEL_BUILD"

# 6. Get ath12k kernel source (upstream, falls back to Ubuntu PPA)
UPSTREAM_VER="7.0.1"
TARBALL="$WORK/linux.tar.xz"
rm -rf "$WORK/kernel-source"
info "Downloading kernel source v$UPSTREAM_VER for ath12k driver ..."
set +e
wget -q --timeout=60 "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${UPSTREAM_VER}.tar.xz" -O "$TARBALL" 2>&1
DL_OK=$?
set -e

if [ $DL_OK -ne 0 ] || [ ! -s "$TARBALL" ]; then
    info "kernel.org download failed. Falling back to Ubuntu source PPA ..."
    # Add the Resolute Concept PPA and apt-get source
    mkdir -p /etc/apt/sources.list.d
    echo "deb-src https://ppa.launchpadcontent.net/ubuntu-concept/x1e/ubuntu resolute main" > /etc/apt/sources.list.d/resolute-source.list
    apt-get update -qq 2>/dev/null
    apt-get source -qq linux-image-7.0.0-22-qcom-x1e 2>&1 || true
    EXTRACTED=$(find "$WORK" -maxdepth 1 -name "linux-*" -type d 2>/dev/null | head -1 || true)
    if [ -n "$EXTRACTED" ]; then
        mv "$EXTRACTED" "$WORK/kernel-source"
    fi
else
    info "Extracting kernel source ..."
    mkdir -p "$WORK/kernel-source"
    tar -xJf "$TARBALL" -C "$WORK" 2>/dev/null
    EXTRACTED=$(find "$WORK" -maxdepth 1 -type d -name "linux-${UPSTREAM_VER}*" | head -1 || true)
    if [ -n "$EXTRACTED" ]; then
        rm -rf "$WORK/kernel-source"
        mv "$EXTRACTED" "$WORK/kernel-source"
    fi
    rm -f "$TARBALL"
fi

# Verify we have ath12k source
ATH12K_SRC="$WORK/kernel-source/drivers/net/wireless/ath/ath12k"
if [ ! -d "$ATH12K_SRC" ]; then
    echo "ath12k source not found. Tried kernel.org and Ubuntu PPA."
    echo "Contents of $WORK:"
    ls -la "$WORK/"
    exit 1
fi
info "ath12k source: $ATH12K_SRC"

# 7. Apply wifi patches to ath12k source
if grep -q "disable-rfkill" "$ATH12K_SRC/core.c" 2>/dev/null; then
    info "WiFi patches already present in ath12k source, skipping ..."
else
    info "Applying WiFi patches to ath12k ..."
    for p in "$PATCHES_DIR"/0002-*.patch "$PATCHES_DIR"/0004-*.patch; do
        pname=$(basename "$p")
        if [ -f "$p" ]; then
            echo "  $pname"
            patch -d "$WORK/kernel-source" -p1 < "$p"
        fi
    done
fi

# 8. Build ONLY the ath12k module against the kernel build tree
info "Building patched ath12k module ..."
make -C "$KERNEL_BUILD" M="$ATH12K_SRC" modules 2>&1

# Verify the module was built and check vermagic
BUILT_KO=$(find "$ATH12K_SRC" -name "*.ko" 2>/dev/null | head -1 || true)
if [ -n "$BUILT_KO" ]; then
    BUILT_VERMAGIC=$(modinfo -F vermagic "$BUILT_KO" 2>/dev/null || echo "unknown")
    info "Built module vermagic: $BUILT_VERMAGIC"
else
    echo "Failed to build ath12k module"
    exit 1
fi

# 9. Inject patched module into rootfs
info "Injecting patched modules into rootfs ..."
MOD_DIR=$(find "$WORK/rootfs/lib/modules/$KVER" -type d -name "ath12k" 2>/dev/null | head -1 || true)
if [ -z "$MOD_DIR" ]; then
    echo "ath12k module directory not found"
    exit 1
fi

# Backup originals
cp -r "$MOD_DIR" "${MOD_DIR}.orig"

# Replace with patched modules (compress with zstd to match ISO format)
for ko in "$ATH12K_SRC"/*.ko "$ATH12K_SRC"/wifi7/*.ko; do
    [ -f "$ko" ] || continue
    rel="${ko#$ATH12K_SRC/}"
    target="$MOD_DIR/$rel"
    mkdir -p "$(dirname "$target")"
    zstd -f --quiet "$ko" -o "${target}.zst"
    echo "  Installed ${rel}.zst"
done

# Update module dependencies
depmod -b "$WORK/rootfs" "$KVER" 2>/dev/null || true

# 10. Install packages via chroot
info "Installing packages in rootfs ..."
mount --bind /proc  "$WORK/rootfs/proc"
mount --bind /sys   "$WORK/rootfs/sys"
mount --bind /dev   "$WORK/rootfs/dev"
mkdir -p "$WORK/rootfs/cdrom"
mount --bind "$WORK/iso" "$WORK/rootfs/cdrom"
cp /etc/resolv.conf "$WORK/rootfs/etc/resolv.conf"

chroot "$WORK/rootfs" apt-get update -qq
chroot "$WORK/rootfs" apt-get install -y -qq curl openssh-server net-tools
chroot "$WORK/rootfs" systemctl enable ssh
chroot "$WORK/rootfs" bash -c 'id -u ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu'
echo "ubuntu:12345678" | chroot "$WORK/rootfs" chpasswd
chroot "$WORK/rootfs" bash -c 'curl -fsSL https://opencode.ai/install | bash'
ln -sf /root/.opencode/bin/opencode "$WORK/rootfs/usr/local/bin/opencode"
info "  Installed opencode (symlinked to /usr/local/bin)"

umount "$WORK/rootfs/cdrom"
umount "$WORK/rootfs/proc" "$WORK/rootfs/sys" "$WORK/rootfs/dev"

# 11. Decompress firmware files (kernel firmware loader can't find .zst files)
info "Decompressing firmware files ..."
find "$WORK/rootfs/lib/firmware" -name "*.zst" -exec zstd -d --rm -q {} \; 2>/dev/null || true

# 12. Install ALL Surface Pro 11 WiFi firmware from Windows driver store
#
#     CRITICAL: amss.bin, m3.bin, and bdwlan.elf MUST all come from the same
#     Windows driver package. Mixing Windows board data (bdwlan.elf) with the
#     ISO's amss.bin/m3.bin causes the firmware to crash during QMI board data
#     transfer — the driver reports "qmi failed to load board data file:-110"
#     (ETIMEDOUT) after a 10-second timeout.
#
#     The ISO's board-2.bin has no matching entry for the SP11 (qmi-board-id=255),
#     so the driver falls through to board.bin. We keep board-2.bin for its REGDB
#     entries (regulatory database), which are version-stable across firmware
#     releases.
info "Installing Surface Pro 11 WiFi firmware from Windows driver store ..."
FW_DIR="$WORK/rootfs/lib/firmware/ath12k/WCN7850/hw2.0"

FW_MISSING=0

# amss.bin — main firmware (loaded via MHI before QMI starts)
# Windows driver store names this wlanfw20.mbn (also an ELF, 6 MB)
AMSS_SRC=""
for f in /build/firmware/amss.bin /build/firmware/wlanfw20.mbn; do
    [ -f "$f" ] && AMSS_SRC="$f" && break
done
if [ -n "$AMSS_SRC" ]; then
    cp "$AMSS_SRC" "$FW_DIR/amss.bin"
    info "  Installed $(basename "$AMSS_SRC") as amss.bin (main firmware)"
else
    info "  WARNING: amss.bin/wlanfw20.mbn not found — QMI -110 timeout likely"
    info "           without version-matched firmware. Extract from Windows"
    info "           driver store (see README 'WiFi firmware' section)."
    FW_MISSING=1
fi

# m3.bin — M3 microcontroller firmware (loaded after board data)
# Windows driver store names this phy_ucode20.elf
M3_SRC=""
for f in /build/firmware/m3.bin /build/firmware/phy_ucode20.elf; do
    [ -f "$f" ] && M3_SRC="$f" && break
done
if [ -n "$M3_SRC" ]; then
    cp "$M3_SRC" "$FW_DIR/m3.bin"
    info "  Installed $(basename "$M3_SRC") as m3.bin (M3 microcontroller firmware)"
else
    info "  WARNING: m3.bin/phy_ucode20.elf not found — must match amss.bin version"
    FW_MISSING=1
fi

# bdwlan.elf → board.bin — board-specific RF config / calibration data
if [ -f "/build/firmware/bdwlan.elf" ]; then
    cp "/build/firmware/bdwlan.elf" "$FW_DIR/board.bin"
    info "  Installed bdwlan.elf as board.bin (board data fallback)"
else
    info "  WARNING: bdwlan.elf not found — no board data for SP11 hardware"
    FW_MISSING=1
fi

# regdb.bin — regulatory database (optional, may be in board-2.bin)
if [ -f "/build/firmware/regdb.bin" ]; then
    cp "/build/firmware/regdb.bin" "$FW_DIR/regdb.bin"
    info "  Installed regdb.bin (regulatory database)"
fi

if [ "$FW_MISSING" -ne 0 ]; then
    info "  Some firmware files missing — WiFi may not work. See README."
fi

# 13. Resquash
info "Resquashing rootfs ..."
mksquashfs "$WORK/rootfs" "$WORK/filesystem.squashfs" -comp zstd -b 1M -noappend &>/dev/null

# 13. Replace in ISO directory
cp "$WORK/filesystem.squashfs" "$SQUASH"

# 14. Repack ISO with proper hybrid layout (MBR + GPT + El Torito)
info "Repacking ISO ..."
EFI_IMG="boot/grub/efi.img"
xorriso -as mkisofs \
    -V "Ubuntu-Concept-Resolute-SP11" \
    -o "$OUTPUT_ISO" \
    -r -J -joliet-long -cache-inodes \
    -e "$EFI_IMG" -no-emul-boot \
    -append_partition 2 0xef "$WORK/iso/$EFI_IMG" \
    -partition_cyl_align all \
    -isohybrid-gpt-basdat \
    "$WORK/iso" &>/dev/null

info "Done! Patched ISO: $OUTPUT_ISO"
INNER_EOF

chmod +x "$BUILD_DIR/patch-inner.sh"

docker run --rm --privileged --platform linux/arm64 \
    -v "$BUILD_DIR:/build" \
    -v "$SCRIPT_DIR/patches:/build/patches:ro" \
    -v "$SCRIPT_DIR/firmware:/build/firmware:ro" \
    sp11-iso-patcher \
    bash /build/patch-inner.sh

echo ""
info "Patched ISO ready: $OUTPUT_ISO"
echo ""
echo "Flash to USB:  sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress"
echo ""
