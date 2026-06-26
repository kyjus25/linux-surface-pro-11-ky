# linux-surface-pro-11-ky

Patches the Ubuntu Concept "Resolute" ARM64 ISO with ath12k WiFi driver fixes
and boot workarounds for the Surface Pro 11 (WCN7850).

## What it fixes

- **WiFi hard-blocked** — rfkill disable via devicetree property (patch 2)
- **MAC address** — allows setting MAC via devicetree (patch 4)
- **Goldilocks Maneuver** — replaces Microsoft shim with full GRUB for reliable boot
- **efi=novamap** — works around EFI memory map issues on Snapdragon X Elite
- **Audio blacklist** — prevents audio DSP hangs from blocking boot

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
6. Compresses modules with zstd and injects them into the rootfs
7. Re-squashes and re-packs as a hybrid MBR+GPT+El Torito ISO

## Patches

From [dwhinham/kernel-surface-pro-11](https://github.com/dwhinham/kernel-surface-pro-11),
only patches 2 and 4 are applied (1 and 3 are dt-bindings/DTS and are skipped
since the module is built against the ISO's pre-existing kernel build tree):

| Patch | Applied | Purpose |
|-------|---------|---------|
| `0001` | No | dt-bindings: add disable-rfkill property |
| `0002` | **Yes** | ath12k: support disabling rfkill via devicetree |
| `0003` | No | DTS: disable rfkill for wifi0 on x1e80100-denali |
| `0004` | **Yes** | ath12k: allow setting MAC address via devicetree |

## Files

| Path | Purpose |
|------|---------|
| `patch-ubuntu-iso.sh` | Main script |
| `patches/*.patch` | ath12k patches |
| `build/` | Auto-generated (ignored by git) |
