# Reset Mechanism (measured 2026-09-23)

## What happens on reset
- `/etc` and `/usr` are wiped and restored from the platform base image.
- System users are deleted and `/etc/passwd` is restored (root's home reverts to `/root`; any extra users are gone).
- App data outside `~` is lost (`/var/lib/docker`, etc.).
- Running processes **may survive** (open file handles stay valid) even though their binaries are deleted — new processes can't start.
- **Resets can occur without a kernel reboot.** `uptime` is NOT a reliable reset detector.

## What persists
- Everything under `/home/hatch` (`~`) — the only durable storage.
- Base image contents (restored each reset).

## Base image includes / excludes (verified)
- Present: `crun`, `python3`, `git`, `curl`, `wget`, `/opt/hatch`, dpkg database.
- Absent: `docker`, `dockerd`, `containerd`, `runc`, `openssh-server`.

## Observed frequency
3 resets in ~2.5 hours on 2026-09-23. Design as if a reset can happen at any time.

## Reliable reset detection
Check file existence (e.g. `[ -x /usr/bin/dockerd ]`), not uptime. Idempotent repair
scripts subsume detection: every run verifies "everything that should exist exists".

## Keeping service data across resets (pattern)
Only `~` survives. For any stateful service, point its data directory into `~`:
- Docker: set `"data-root": "/home/hatch/docker-data"` in `/etc/docker/daemon.json`.
  Images, containers, and named volumes then survive resets untouched; the repair
  script only recreates the dir if deleted. Verified 2026-09-24: after moving
  `/var/lib/docker` to `~/docker-data`, a reset would leave all Docker resources
  intact (dockerd itself is still reinstalled from cached debs by the repair script).
- Same idea applies to databases etc.: configure their data dir under `~`, and have
  the repair script `mkdir -p` it and rewrite the config pointing there.
