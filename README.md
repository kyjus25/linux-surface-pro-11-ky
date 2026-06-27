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
   can find them without transparent decompression
7. Installs **all** WiFi firmware (`amss.bin`, `m3.bin`, `bdwlan.elf` as
   `board.bin`) from the Windows driver store — version-matched to prevent
   QMI board data timeout (see [WiFi firmware](#wifi-firmware))
8. Compresses modules with zstd and injects them into the rootfs
9. Re-squashes and re-packs as a hybrid MBR+GPT+El Torito ISO

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

## WiFi firmware

The Ubuntu firmware package's `board-2.bin` doesn't have an entry (`qmi-board-id=255`) for the
Surface Pro 11 LCD (X1P64100). We extract **all** WiFi firmware files from the
Windows driver store on the device itself.

**All firmware files must come from the same Windows driver package.** Mixing
the Windows `bdwlan.elf` with the ISO's `amss.bin`/`m3.bin` causes the firmware
to crash during QMI board data transfer — the driver reports
`qmi failed to load board data file:-110` (ETIMEDOUT) after a 10-second timeout.

### Extracting firmware from Windows

On Windows (PowerShell as Admin), copy these files from the driver store:

```
C:\Windows\System32\DriverStore\FileRepository\qcwlanhmt8380.inf_arm64_f6c170edbe88d474\
```

| Windows file | Copy to repo as | Installed as | Purpose |
|--------------|-----------------|--------------|---------|
| `wlanfw20.mbn` | `firmware/wlanfw20.mbn` | `amss.bin` | Main firmware (ELF, loaded via MHI) |
| `phy_ucode20.elf` | `firmware/phy_ucode20.elf` | `m3.bin` | M3 microcontroller firmware (ELF) |
| `bdwlan.elf` | `firmware/bdwlan.elf` | `board.bin` | Board data (RF config, calibration) |
| `regdb.bin` | `firmware/regdb.bin` | `regdb.bin` | Regulatory database (optional) |

The script auto-detects both Linux names (`amss.bin`, `m3.bin`) and Windows
names (`wlanfw20.mbn`, `phy_ucode20.elf`). All files are ELF — the `.mbn`
extension is just Qualcomm's naming convention. Simply copy the entire driver
store folder contents into `firmware/`.

The script copies these into `/lib/firmware/ath12k/WCN7850/hw2.0/` in the
rootfs, overwriting the ISO's versions. The ISO's `board-2.bin` is kept for its
REGDB entries (regulatory database), which are version-stable across firmware
releases. Since `board-2.bin` has no matching board data entry for the SP11
(`qmi-board-id=255`), the driver falls through to `board.bin`.

### Troubleshooting: QMI board data timeout (-110)

If dmesg shows `qmi failed to load board data file:-110` (ETIMEDOUT):

1. **Firmware version mismatch** — the most common cause. Ensure `amss.bin`,
   `m3.bin`, and `bdwlan.elf` all come from the same Windows driver store
   directory. Do not mix Windows firmware with the ISO's firmware.
2. **Missing firmware files** — SSH in and verify:
   ```bash
   ls -la /lib/firmware/ath12k/WCN7850/hw2.0/
   # Should show: amss.bin  m3.bin  board.bin  board-2.bin
   ```
3. **QMI debug logging** — reload the module with debug enabled:
   ```bash
   sudo modprobe -r ath12k
   sudo modprobe ath12k debug_mask=0x40000
   dmesg | grep ath12k
   ```
4. **rfkill** — check if WiFi is hard-blocked:
   ```bash
   rfkill list
   ```

Or run the bundled diagnostic script:

```bash
sudo /path/to/debug-wifi.sh
```

## Files

| Path | Purpose |
|------|---------|
| `patch-ubuntu-iso.sh` | Main script |
| `debug-wifi.sh` | Runtime WiFi diagnostic script (run on SP11) |
| `patches/*.patch` | ath12k patches |
| `firmware/amss.bin` | Main WiFi firmware from Windows driver |
| `firmware/m3.bin` | M3 microcontroller firmware from Windows driver |
| `firmware/bdwlan.elf` | Board data from Windows driver (installed as `board.bin`) |
| `firmware/regdb.bin` | Regulatory database from Windows driver (optional) |
| `build/` | Auto-generated (ignored by git) |
