#!/bin/bash
# Set Bluetooth MAC from UEFI variable before bluetoothd starts.
EFI_VAR="MacAddressEmulationAddress-b7f95555-4ea5-4786-b088-78ba350a1b56"
EFI_PATH="/sys/firmware/efi/efivars/$EFI_VAR"

MAC=$(hexdump -s 4 -n 6 -e '5/1 "%02X:" 1/1 "%02X"' "$EFI_PATH" 2>/dev/null)
if [ -z "$MAC" ]; then
    echo "sp11-bt-addr: UEFI variable not found, using default MAC" >&2
    exit 0
fi

# Wait for hci0 to appear (up to 10 seconds)
for i in $(seq 1 50); do
    [ -e /sys/class/bluetooth/hci0 ] && break
    sleep 0.2
done
if [ ! -e /sys/class/bluetooth/hci0 ]; then
    echo "sp11-bt-addr: hci0 not found after 10s, giving up" >&2
    exit 0
fi

echo "sp11-bt-addr: setting MAC to $MAC" >&2
btmgmt --index 0 power off >/dev/null 2>&1 || true
echo "y" | btmgmt --index 0 public-addr "$MAC" >/dev/null 2>&1 || {
    echo "sp11-bt-addr: btmgmt failed, continuing with default MAC" >&2
    exit 0
}
echo "sp11-bt-addr: MAC set successfully" >&2
