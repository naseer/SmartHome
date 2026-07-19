#!/usr/bin/env python3
"""Trim what Home Assistant exposes to Google Home.

HA freezes each entity's exposure decision into core.entity_registry under
options["cloud.google_assistant"]["should_expose"]. Once stored, the default
rules (entity_category, domain allowlist) are never consulted again -- so the
only way to un-expose an entity is to rewrite that stored value.

Keeps a small allowlist exposed; sets should_expose False on everything else.
Also sets expose_new False so future entities do not auto-populate Google Home.

Run with Home Assistant STOPPED. Writes .bak-<timestamp> copies first.
"""
import json
import shutil
import sys
import time

STORAGE = "/opt/stack/homeassistant/config/.storage/"
ASSISTANT = "cloud.google_assistant"

# Exposed to Google. Everything else gets un-exposed.
KEEP_DOMAINS = {"light"}
KEEP_ENTITIES = {"climate.thermostat_hub_w200", "todo.shopping_list"}


def keep(entity_id):
    return entity_id.split(".")[0] in KEEP_DOMAINS or entity_id in KEEP_ENTITIES


def backup(path):
    dest = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, dest)
    print(f"   backup: {dest}")


def trim_registry(apply_changes):
    path = STORAGE + "core.entity_registry"
    with open(path) as fh:
        data = json.load(fh)

    removed, kept = [], []
    for entry in data["data"]["entities"]:
        opts = entry.get("options") or {}
        if not (opts.get(ASSISTANT) or {}).get("should_expose"):
            continue
        if keep(entry["entity_id"]):
            kept.append(entry["entity_id"])
            continue
        removed.append(entry["entity_id"])
        if apply_changes:
            # Rebuild rather than mutate in place, matching repo style.
            entry["options"] = {
                **opts,
                ASSISTANT: {**opts[ASSISTANT], "should_expose": False},
            }

    if apply_changes:
        backup(path)
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
    return removed, kept


def disable_expose_new(apply_changes):
    path = STORAGE + "homeassistant.exposed_entities"
    with open(path) as fh:
        data = json.load(fh)

    current = data["data"].setdefault("assistants", {}).get(ASSISTANT, {})
    if current.get("expose_new") is False:
        return False
    if apply_changes:
        backup(path)
        data["data"]["assistants"][ASSISTANT] = {**current, "expose_new": False}
        with open(path, "w") as fh:
            json.dump(data, fh, indent=2)
    return True


def main():
    apply_changes = "--apply" in sys.argv
    mode = "APPLY" if apply_changes else "DRY RUN"
    print(f"== {mode} ==\n")

    removed, kept = trim_registry(apply_changes)
    changed = disable_expose_new(apply_changes)

    print(f"UN-EXPOSE ({len(removed)}):")
    for eid in sorted(removed):
        print("   -", eid)
    print(f"\nKEEP EXPOSED ({len(kept)}):")
    for eid in sorted(kept):
        print("   +", eid)
    print(f"\nexpose_new -> False: {'yes' if changed else 'already set'}")

    if not apply_changes:
        print("\nNothing written. Re-run with --apply.")


if __name__ == "__main__":
    main()
