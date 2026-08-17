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

  # ==========================================================================================
  # ALL heredocs below are QUOTED (<<'EOF') so the shell performs NO expansion inside them --
  # no $VAR, and critically no command substitution. Values are injected afterwards with sed.
  #
  # WHY: on 2026-08-17 an UNQUOTED heredoc contained explanatory comments with backticks --
  # `systemctl enable ssh` and `|| true` -- and bash EXECUTED them against the workstation
  # writing the card. Privileged commands ran on the wrong machine, and the script died on a
  # syntax error. Documentation prose became executable code. Never use an unquoted heredoc for
  # a config file that may contain prose, quotes or shell metacharacters.
  # ==========================================================================================

  sudo tee "$MNT/meta-data" > /dev/null <<'EOF'
dsmode: local
instance_id: @@INSTANCE_ID@@
local-hostname: @@HOSTNAME@@
EOF

  sudo tee "$MNT/user-data" > /dev/null <<'EOF'
#cloud-config
# Written by wallpi-stack/write-firstboot-config.sh
hostname: @@HOSTNAME@@
manage_etc_hosts: true
timezone: @@TZ@@

users:
  - name: @@USERNAME@@
    groups: [adm,dialout,cdrom,sudo,audio,video,plugdev,games,users,input,render,netdev,gpio,i2c,spi]
    shell: /bin/bash
    lock_passwd: false
    passwd: "@@UHASH@@"
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - "@@PUBKEY@@"

# Key auth only; the account password is for console and sudo.
ssh_pwauth: false

# Enable sshd three ways. Pi OS Lite ships it disabled, and cloud-init configures SSH without
# starting it. Debian 13 moved OpenSSH to socket activation, so enabling the .service alone can
# succeed while nothing listens on port 22 -- the suspected 2026-08-17 failure.
runcmd:
  - [ sh, -c, "raspi-config nonint do_ssh 0 || true" ]
  - [ sh, -c, "systemctl enable --now ssh.socket 2>/dev/null || true" ]
  - [ sh, -c, "systemctl enable --now ssh.service 2>/dev/null || true" ]
  - [ sh, -c, "systemctl is-active ssh.socket ssh.service > /boot/firmware/ssh-status.txt 2>&1 || true" ]
  - [ sh, -c, "ss -tlnp >> /boot/firmware/ssh-status.txt 2>&1 || true" ]

keyboard:
  layout: us

packages:
  - avahi-daemon
package_update: true
EOF

  sudo tee "$MNT/network-config" > /dev/null <<'EOF'
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
        "@@SSID@@":
          password: "@@WIFI_SECRET@@"
EOF

  WIFI_SECRET="${WPSK:-}"
  [ -n "$WIFI_SECRET" ] || { echo "!! could not derive a PSK; aborting rather than writing a broken file"; exit 1; }

  # Inject values. Uses a non-/ delimiter and a Python-free approach; values here are hashes,
  # hex PSKs and base64 keys, none of which contain the | delimiter.
  for f in meta-data user-data network-config; do
    sudo sed -i \
      -e "s|@@INSTANCE_ID@@|${NEWID}|g" \
      -e "s|@@HOSTNAME@@|${HOSTNAME_}|g" \
      -e "s|@@TZ@@|${TZ_}|g" \
      -e "s|@@USERNAME@@|${USERNAME}|g" \
      -e "s|@@UHASH@@|${UHASH}|g" \
      -e "s|@@PUBKEY@@|${PUB}|g" \
      -e "s|@@SSID@@|${SSID}|g" \
      -e "s|@@WIFI_SECRET@@|${WIFI_SECRET}|g" \
      "$MNT/$f"
  done

  # Fail loudly if any placeholder survived -- a silent miss would ship a broken config.
  if sudo grep -l "@@" "$MNT"/meta-data "$MNT"/user-data "$MNT"/network-config 2>/dev/null; then
    echo "!! unsubstituted placeholders remain above -- refusing to continue"; exit 1
  fi

  sudo rm -f "$MNT/custom.toml"

  echo ">> wrote cloud-init config (instance_id=${NEWID}); secrets masked:"
  for f in meta-data user-data network-config; do
    echo "   --- $f ---"
    sudo sed -E 's/(passwd:|password:).*/\1 ***MASKED***/' "$MNT/$f" | grep -vE "^\s*#" | grep -v "^\s*$" | sed 's/^/     /'
  done
else
  echo "!! this card expects the older custom.toml mechanism; not implemented here"; exit 1
fi

sudo sync
echo
echo ">> after boot, if SSH still fails, put the card back in the reader and read"
echo "   /boot/firmware/ssh-status.txt -- runcmd writes the ssh unit state and listening"
echo "   sockets there, so a headless failure leaves evidence you can actually read."
echo ">> eject, boot the Pi. It should come up as '${HOSTNAME_}' with SSH key auth."
echo "   ssh ${USERNAME}@${HOSTNAME_}.local     (or find the IP in UniFi)"
echo "   NOTE: cloud-init runs on the FIRST boot after this; give it a couple of minutes."
