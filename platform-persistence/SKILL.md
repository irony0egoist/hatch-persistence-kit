---
name: "platform_persistence"
description: "Make programs and data survive platform VM resets: analyze what persists, cache installers under ~, write idempotent repair scripts, and set up cron health checks. Use when something must keep working across platform resets."
---

# Platform Persistence

## Purpose
The platform periodically wipes the VM (`/etc`, `/usr` restored from base image, system users deleted; only `~` survives). This skill makes any program/data auto-recover after a reset.

## Workflow

1. **Inventory**: list what the program needs — binaries, configs, systemd units, data dirs, pulled artifacts. Check each against the base image (see `references/reset-mechanism.md` for what survives).
2. **Cache materials under `~`**: download `.deb`s into `~/.tool-cache/<tool>/`
   (full closure: include every dependency the base image lacks; never rely on apt
   at repair time). Install via `~/.platform-repair/bin/install-cached-debs <dir>
   <binary...>` (idempotent). Configs go under `~` as templates (or embedded in the
   script); stateful services must point their data dir into `~` (e.g. dockerd's
   `data-root`). Keep a manifest where useful (e.g. `images.txt`).
3. **Write an idempotent repair script** `~/.platform-repair/repair-<name>.sh` following the template in `references/repair-script-template.sh`. It must: check each component with independent double signals, rebuild only what's missing (install via `install-cached-debs`, never apt, on the critical path), re-verify functionally after any repair, and print exactly one of:
   - `[<tag>] OK: all healthy` (nothing to do)
   - `[<tag>] FIXED: <what>` (repaired something)
   - `[<tag>] ERROR: <what>` (needs human)
4. **Test it**: run once (it should repair), run again (it must print `OK: all healthy`).
5. **Schedule**: `cron.add` a `task` every `5m` that runs the script via exec and notifies the user in Chinese only on `FIXED:`/`ERROR:`. Keep it independent from other repair crons.
6. **Register**: add a row to the persistence inventory (memory or `~/.platform-repair/README.md`).

## Output Contract
- The repair script path and its cron job id.
- A one-line summary per component: cached where, rebuilt how.
- Known limits (recovery window, network deps, non-persistent state).

## Operating Rules
1. Never store passwords, keys, or proxy credentials in scripts or logs.
2. Repair scripts must be safe to run any number of times; never `rm -rf` outside the component's own paths.
3. Do not rely on `uptime` to detect resets — resets can happen without reboot. Detect by file existence.
4. Prefer `~/.tool-cache/<tool>/` + `install-cached-debs` over apt at repair time (faster, no repo dependency). Register every managed tool in `~/.platform-repair/TOOLS.md`.
5. One subsystem per script/cron; don't couple unrelated repairs.
6. Container state is ephemeral by design — persist data via volumes/bind-mounts under `~`, never inside `/var/lib/docker`.
