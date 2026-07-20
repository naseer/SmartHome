#!/usr/bin/env python3
"""Add the MQTT config entry to Home Assistant by writing core.config_entries.

HA has no supported CLI for adding an integration, but the MQTT entry is a plain
config entry. This crafts one matching what the 2026.7 config flow produces
(VERSION 2 / MINOR_VERSION 1: connection in `data`, discovery in `options`) and
appends it to the store envelope cloned from an existing entry.

MUST run with Home Assistant STOPPED (HA rewrites .storage on shutdown).
Idempotent: refuses if an mqtt entry already exists. Backs up first.
Reads MQTT creds from /opt/stack/.env -- never printed.
"""
import json
import os
import secrets
import shutil
import sys
import time
from datetime import datetime, timezone

STORE = "/opt/stack/homeassistant/config/.storage/core.config_entries"
ENV = "/opt/stack/.env"
BROKER = "127.0.0.1"
PORT = 1883


def read_env(path):
    creds = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            creds[key.strip()] = val.strip()
    return creds


def new_ulid():
    # Crockford base32, 26 chars: 48-bit ms timestamp + 80 bits randomness.
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    value = (int(time.time() * 1000) << 80) | secrets.randbits(80)
    out = "".join(
        alphabet[(value >> (5 * i)) & 31] for i in range(25, -1, -1)
    )
    return out


def main():
    apply_changes = "--apply" in sys.argv
    env = read_env(ENV)
    user = env.get("MQTT_USER")
    password = env.get("MQTT_PASSWORD")
    if not user or not password:
        sys.exit("!! MQTT_USER/MQTT_PASSWORD not found in .env")

    with open(STORE) as fh:
        store = json.load(fh)

    entries = store["data"]["entries"]
    if any(e["domain"] == "mqtt" for e in entries):
        sys.exit("!! an mqtt entry already exists -- nothing to do")

    now = datetime.now(timezone.utc).isoformat()
    entry = {
        "created_at": now,
        "data": {
            "broker": BROKER,
            "port": PORT,
            "username": user,
            "password": password,
        },
        "disabled_by": None,
        "discovery_keys": {},
        "domain": "mqtt",
        "entry_id": new_ulid(),
        "minor_version": 1,
        "modified_at": now,
        "options": {
            "discovery": True,
            "discovery_prefix": "homeassistant",
        },
        "pref_disable_new_entities": False,
        "pref_disable_polling": False,
        "source": "user",
        "subentries": [],
        "title": BROKER,
        "unique_id": None,
        "version": 2,
    }

    # Print the entry with the password masked so the action is auditable.
    audit = {**entry, "data": {**entry["data"], "password": "<REDACTED>"}}
    print(json.dumps(audit, indent=1))

    if not apply_changes:
        print("\nDRY RUN -- nothing written. Re-run with --apply.")
        return

    backup = f"{STORE}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(STORE, backup)
    print(f"backup: {backup}")

    new_store = {
        **store,
        "data": {**store["data"], "entries": [*entries, entry]},
    }
    with open(STORE, "w") as fh:
        json.dump(new_store, fh, indent=2)
    os.chmod(STORE, 0o600)
    print("mqtt entry written.")


if __name__ == "__main__":
    main()
