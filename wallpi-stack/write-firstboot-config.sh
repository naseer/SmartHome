#!/usr/bin/env bash
# Provision a freshly-flashed Raspberry Pi OS card so the Pi comes up headless with SSH key auth,
# a user account, a hostname, and WiFi -- no keyboard or monitor.
#
# RUN ON naahmed-linux with the card inserted. Needs a real terminal (prompts for two passwords);
# Claude Code's `!` mode pipes stdin and the prompts will silently get EOF.
#
# ============================================================================================
# WHICH MECHANISM: this image uses CLOUD-INIT, not custom.toml.
#
# The first version of this script wrote /boot/firmware/custom.toml -- the Bookworm-era mechanism.
# On the Trixie-based image (2026-06-18) that file is simply IGNORED. Verified 2026-08-12: after a
# boot the card still had custom.toml sitting untouched, cmdline.txt had no firstboot hook, the
# hostname was the default `raspberrypi`, and sshd was not running. The boot partition instead
# carries `user-data`, `network-config` and `meta-data` -- cloud-init's NoCloud datasource.
#
# So: DO NOT write custom.toml on this image. Detect and write whichever the card expects.
#
# CLOUD-INIT CACHES BY instance_id. The stock meta-data pins `instance_id: rpios-image`, so once the
# Pi has booted ONCE it considers itself provisioned and will ignore edited user-data forever. This
# script writes a NEW instance_id, which is what makes a re-provision actually take effect on a card
# that has already booted.
# ============================================================================================
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
BOOTPART="${DEV}1"
[ -b "$BOOTPART" ] || { echo "!! $BOOTPART missing"; exit 1; }
FSTYPE=$(lsblk -no FSTYPE "$BOOTPART" | head -1)
[ "$FSTYPE" = "vfat" ] || { echo "!! $BOOTPART is '$FSTYPE', expected vfat -- wrong device?"; exit 1; }

MNT=$(mktemp -d)
cleanup() { sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
sudo mount "$BOOTPART" "$MNT"

if [ -f "$MNT/user-data" ]; then
  MECH=cloud-init
elif [ -f "$MNT/cmdline.txt" ]; then
  MECH=custom-toml
else
  echo "!! $BOOTPART does not look like a Pi boot partition"; exit 1
fi
echo ">> device=$BOOTPART  mechanism=$MECH"
echo ">> host=$HOSTNAME_ user=$USERNAME ssid=$SSID country=$COUNTRY tz=$TZ_"
echo

read -rsp "Password for the '$USERNAME' account on the Pi: " UPW; echo
[ -n "$UPW" ] || { echo "!! empty, aborting"; exit 1; }
read -rsp "WiFi password for '$SSID': " WPW; echo
[ -n "$WPW" ] || { echo "!! empty, aborting"; exit 1; }
UHASH=$(openssl passwd -6 "$UPW")
# Derive the PSK so the passphrase itself is not written to the card.
WPSK=$(wpa_passphrase "$SSID" "$WPW" 2>/dev/null | awk -F= '/^\tpsk=/ {print $2}' | tail -1 || true)
unset UPW WPW
PUB=$(cat "$PUBKEY")

if [ "$MECH" = "cloud-init" ]; then
  # A NEW instance_id is what forces cloud-init to re-run on an already-booted card.
  NEWID="${HOSTNAME_}-$(date +%Y%m%d%H%M%S)"

  sudo tee "$MNT/meta-data" > /dev/null <<EOF
dsmode: local
instance_id: ${NEWID}
local-hostname: ${HOSTNAME_}
EOF

  sudo tee "$MNT/user-data" > /dev/null <<EOF
#cloud-config
# Written by wallpi-stack/write-firstboot-config.sh
hostname: ${HOSTNAME_}
manage_etc_hosts: true
timezone: ${TZ_}

users:
  - name: ${USERNAME}
    # Same group set Pi OS gives its default user, so gpio/i2c/audio/video all work.
    groups: [adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,render,netdev,gpio,i2c,spi]
    shell: /bin/bash
    lock_passwd: false
    passwd: "${UHASH}"
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "${PUB}"

# Key auth only. The account password exists for the console and sudo, not for SSH.
ssh_pwauth: false

# EXPLICITLY ENABLE sshd. This is NOT automatic: on Pi OS Lite the ssh service is disabled by
# default, and cloud-init's ssh_pwauth / ssh_authorized_keys CONFIGURE ssh without STARTING it.
# Measured 2026-08-17: cloud-init ran correctly (hostname applied, avahi installed, wallpi.local
# resolving) yet port 22 was closed, which reads as "provisioning failed" when it did not.
runcmd:
  - [ systemctl, enable, --now, ssh ]

keyboard:
  layout: us

packages:
  # avahi-daemon is what makes ${HOSTNAME_}.local resolve; without it you need the IP.
  - avahi-daemon
package_update: true
EOF

  # netplan v2. The PSK hex is accepted in place of the passphrase, so no plaintext on the card.
  WIFI_SECRET="${WPSK:-PLAINTEXT_FALLBACK}"
  sudo tee "$MNT/network-config" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      access-points:
        "${SSID}":
          password: "${WIFI_SECRET}"
EOF

  # The stale custom.toml from the previous attempt would only confuse a future reader.
  sudo rm -f "$MNT/custom.toml"

  echo ">> wrote cloud-init config (instance_id=${NEWID}); secrets masked:"
  for f in meta-data user-data network-config; do
    echo "   --- $f ---"
    sudo sed -E 's/(passwd:|password:).*/\1 ***MASKED***/' "$MNT/$f" | grep -vE "^\s*#" | grep -v '^\s*$' | sed 's/^/     /'
  done
else
  echo "!! this card expects the older custom.toml mechanism; not implemented here"; exit 1
fi

sudo sync
echo
echo ">> eject, boot the Pi. It should come up as '${HOSTNAME_}' with SSH key auth."
echo "   ssh ${USERNAME}@${HOSTNAME_}.local     (or find the IP in UniFi)"
echo "   NOTE: cloud-init runs on the FIRST boot after this; give it a couple of minutes."
