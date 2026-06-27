# linux-surface-pro-11-ky

Patches the Ubuntu Concept "Resolute" ARM64 ISO with ath12k WiFi driver fixes
and boot workarounds for the Surface Pro 11 (WCN7850).

## What it fixes

- **WiFi hard-blocked** — unconditionally skips rfkill in the ath12k driver
  (firmware hard-blocks rfkill; devicetree property can't be set on UEFI ARM64)
- **MAC address** — allows setting MAC via devicetree (patch 4)
- **[Goldilocks Maneuver](https://github.com/linux-surface/linux-surface/discussions/2128)** — replaces Microsoft shim with full GRUB for reliable boot
- **efi=novamap** — works around EFI memory map issues on Snapdragon X Elite
- **Audio blacklist** — prevents audio DSP hangs from blocking boot

## Pre-installed packages

- **curl** — for downloading files
- **openssh-server** — enabled on boot, ready for remote debugging
- **net-tools** — ifconfig, netstat, etc.
- **opencode** — installed via `curl -fsSL https://opencode.ai/install | bash`

## SSH access

The live USB has SSH enabled by default for remote debugging:

```bash
# Default credentials
User: ubuntu
Pass: 12345678

# Connect
ssh ubuntu@<ip-address>
```

## Usage

```bash
./patch-ubuntu-iso.sh                       # download ISO + patch
./patch-ubuntu-iso.sh --local-iso /path/to/resolute-desktop-arm64+x1e.iso

sudo dd if=build/resolute-desktop-arm64+x1e-wifi-patched.iso \
       of=/dev/sdX bs=4M status=progress
```

Requires only Docker. Runs entirely inside an `arm64v8/ubuntu:26.04` container.

## How it works

1. Builds a Docker image with GCC 15, xorriso, squashfs-tools, mtools, etc.
2. Extracts the ISO and unsquashes `minimal.squashfs`
3. Replaces `bootaa64.efi` (shim) with `grubaa64.efi` (full GRUB) in both the
   ISO tree and the hidden El Torito EFI boot image
4. Adds `efi=novamap` and audio `module_blacklist` to the kernel cmdline
5. Builds patched `ath12k.ko` and `wifi7/ath12k_wifi7.ko` against the ISO's
   existing kernel build tree (exact vermagic match)
6. Decompresses firmware files (`.zst` → raw) so the kernel firmware loader
   can find `board-2.bin`, `amss.bin`, etc. without transparent decompression
7. Compresses modules with zstd and injects them into the rootfs
8. Re-squashes and re-packs as a hybrid MBR+GPT+El Torito ISO

## Patches

From [dwhinham/kernel-surface-pro-11](https://github.com/dwhinham/kernel-surface-pro-11),
with modifications. Patches 1 and 3 are skipped (dt-bindings/DTS — UEFI ARM64
firmware provides the devicetree, so there are no DTBs to patch in the ISO):

| Patch | Applied | Purpose |
|-------|---------|---------|
| `0001` | No | dt-bindings: add disable-rfkill property |
| `0002` | **Yes** | ath12k: always disable rfkill (modified from original) |
| `0003` | No | DTS: disable rfkill for wifi0 on x1e80100-denali |
| `0004` | **Yes** | ath12k: allow setting MAC address via devicetree |

Patch 0002 was modified: the original checked for a `disable-rfkill`
devicetree property, but since UEFI ARM64 firmware owns the devicetree and
the ISO has no DTBs, the property can never be set. The modified version
unconditionally skips rfkill configuration.

## Files

| Path | Purpose |
|------|---------|
| `patch-ubuntu-iso.sh` | Main script |
| `patches/*.patch` | ath12k patches |
| `build/` | Auto-generated (ignored by git) |
