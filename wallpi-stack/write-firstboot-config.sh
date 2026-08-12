#!/usr/bin/env bash
# Write Raspberry Pi OS first-boot config to a freshly-flashed SD card, so the Pi comes up headless
# on WiFi with SSH key auth and never needs a keyboard or monitor.
#
# RUN ON naahmed-linux, AFTER `dd`-ing the image to the card, with the card still inserted.
# Needs a real terminal: it prompts for two passwords. Claude Code's `!` mode pipes stdin and the
# prompts will silently receive EOF.
#
# Pi OS (Bookworm and later, incl. Trixie) reads /boot/firmware/custom.toml on first boot and then
# deletes it. This replaces the old ssh / userconf.txt / wpa_supplicant.conf trio -- do not mix them.
set -euo pipefail

DEV="${DEV:-/dev/sdb}"
HOSTNAME_="${HOSTNAME_:-wallpi}"
USERNAME="${USERNAME:-$(id -un)}"
SSID="${SSID:-MASN}"
COUNTRY="${COUNTRY:-CA}"
TZ_="${TZ_:-America/Toronto}"
PUBKEY="${PUBKEY:-$HOME/.ssh/id_ed25519.pub}"

[ -b "$DEV" ] || { echo "!! $DEV is not a block device"; exit 1; }
[ -f "$PUBKEY" ] || { echo "!! no public key at $PUBKEY"; exit 1; }

# The boot partition is the FIRST partition of the freshly written image, and it is FAT32.
BOOTPART="${DEV}1"
[ -b "$BOOTPART" ] || { echo "!! $BOOTPART missing -- did the dd finish and the kernel re-read the table?"; exit 1; }
FSTYPE=$(lsblk -no FSTYPE "$BOOTPART")
case "$FSTYPE" in
  vfat|fat32) ;;
  *) echo "!! $BOOTPART is '$FSTYPE', expected vfat. Refusing -- this may be the wrong device."; exit 1 ;;
esac

echo ">> target: $BOOTPART ($FSTYPE) on $DEV"
echo ">> host=$HOSTNAME_ user=$USERNAME ssid=$SSID country=$COUNTRY tz=$TZ_"
echo

read -rsp "Password for the '$USERNAME' account on the Pi: " UPW; echo
[ -n "$UPW" ] || { echo "!! empty, aborting"; exit 1; }
read -rsp "WiFi password for '$SSID': " WPW; echo
[ -n "$WPW" ] || { echo "!! empty, aborting"; exit 1; }

# Hash the account password -- never stored in plaintext on the card.
UHASH=$(openssl passwd -6 "$UPW")
# Derive the WiFi PSK so the plaintext passphrase is not written to the card either.
WPSK=$(wpa_passphrase "$SSID" "$WPW" 2>/dev/null | awk -F= '/^\tpsk=/ {print $2}' | tail -1)
[ -n "$WPSK" ] || { echo "!! wpa_passphrase failed (install wpasupplicant); falling back to plaintext"; WPSK=""; }
unset UPW WPW

MNT=$(mktemp -d)
cleanup() { sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount "$BOOTPART" "$MNT"

if [ -n "$WPSK" ]; then
  WIFI_BLOCK=$(printf 'ssid = "%s"\npassword = "%s"\npassword_encrypted = true\ncountry = "%s"' "$SSID" "$WPSK" "$COUNTRY")
else
  WIFI_BLOCK=$(printf 'ssid = "%s"\npassword = "%s"\npassword_encrypted = false\ncountry = "%s"' "$SSID" "$WPW" "$COUNTRY")
fi

sudo tee "$MNT/custom.toml" > /dev/null <<EOF
# Written by wallpi-stack/write-firstboot-config.sh. Pi OS consumes and DELETES this on first boot.
config_version = 1

[system]
hostname = "${HOSTNAME_}"

[user]
name = "${USERNAME}"
password = "${UHASH}"
password_encrypted = true

[ssh]
enabled = true
# Key auth only. The account password above exists for console/sudo, not for SSH.
password_authentication = false
authorized_keys = [ "$(cat "$PUBKEY")" ]

[wlan]
${WIFI_BLOCK}

[locale]
keymap = "us"
timezone = "${TZ_}"
EOF

sudo sync
echo ">> wrote $MNT/custom.toml:"
sudo sed -E 's/(password = ")[^"]*/\1***MASKED***/' "$MNT/custom.toml" | sed 's/^/     /'
echo
echo ">> eject the card, put it in the Pi, power on. It should appear as '${HOSTNAME_}' on WiFi."
echo "   then:  ssh ${USERNAME}@${HOSTNAME_}.local     (or find it by IP in UniFi)"
