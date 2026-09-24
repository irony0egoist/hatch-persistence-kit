---
name: "sandbox_docker"
description: "Run Docker containers inside the restricted Muse sandbox via crun direct-drive. Standard `docker run` fails here (libnetwork can't manage netns); use docker-run.sh / compose-run.sh instead. Use when the user wants to run containers or compose projects in this environment."
---

# Sandbox Docker

## Purpose
Run Docker images as containers in this sandbox, where the Docker daemon's networking (libnetwork) is incompatible with the sandbox's mount/seccomp restrictions.

## Tooling
All scripts live in `~/workspace/docker-fix/` (persisted under `~`).

**Single container:**
```bash
~/workspace/docker-fix/docker-run.sh <image> [command...]
~/workspace/docker-fix/docker-run.sh hello-world
~/workspace/docker-fix/docker-run.sh alpine id
# 持久化数据：命名卷（dockerd 管理，跨越重置）或 bind mount（host 路径放 ~ 下）
~/workspace/docker-fix/docker-run.sh -v mydata:/data -v ~/work:/work alpine sh
```
Flow: `docker pull/create/export` → build OCI bundle → `crun` runs it via the
`/usr/local/bin/crun-nokeyring` wrapper. Image default Entrypoint/Cmd auto-detected.
`-v name:/dst` creates the named volume via dockerd if missing and bind-mounts
`<data-root>/volumes/<name>/_data`; `-v /host/path:/dst` bind-mounts directly.

**Manage containers** (crun wrapped, no need to call `crun` directly):
```bash
~/workspace/docker-fix/docker-run.sh -d <image> [command...]  # 后台运行
~/workspace/docker-fix/docker-run.sh ps                       # 列出容器
~/workspace/docker-fix/docker-run.sh stop <name>...            # 优雅停止 (SIGTERM→10s→SIGKILL)
~/workspace/docker-fix/docker-run.sh kill <name>...            # 立即 SIGKILL
~/workspace/docker-fix/docker-run.sh logs <name>              # 看 -d 容器的日志
```
Notes: `crun exec` doesn't work in this sandbox (seccomp blocks `setns`), so it
is deliberately not wrapped — use foreground mode for debugging. The sandbox may
reclaim a container's cgroup when the session ends while its processes survive as
orphans (`ps` shows `stopped` but processes live on); `stop`/`kill` detect and
clean these up (matched by mount namespace, safe against pid reuse). Compose
services get stable names `<project>-<svc>` via `CR_CONTAINER_ID`.

**Compose projects:**
```bash
~/workspace/docker-fix/compose-run.sh up [-f compose.yaml] [service...]
~/workspace/docker-fix/compose-run.sh ps|logs <svc>|down [-f compose.yaml]
```
Parses with `docker compose config --format json`, starts services in `depends_on`
order. Supports: `image`, `command`, `entrypoint`, `environment`, `env_file`,
`volumes` (bind mounts and named volumes), `working_dir`. Named volumes are
created via dockerd and live under `<data-root>/volumes/<name>`. See `references/limitations.md`.

## Data persistence across platform resets
dockerd's `data-root` is `/home/hatch/docker-data` (set in `/etc/docker/daemon.json`
and enforced by the repair script). **Images, containers, and named volumes survive
resets** — only running processes don't (restart them with `docker-run.sh` /
`compose-run.sh up` afterwards). For container data that must survive: use a named
volume (`-v mydata:/data`) or a bind mount under `~` (`-v ~/work:/work`).

**Rebuilding the stack after a platform reset:**
```bash
/home/hatch/.platform-repair/repair-docker.sh   # idempotent; also run by cron every 5m
```
This reinstalls docker-ce from cached debs, restores the crun wrapper and
`daemon.json` (including `data-root`), starts dockerd. Images/containers/volumes
are already intact via `data-root` under `~`; the image tar cache in
`~/workspace/docker-fix/image-cache/` is now only a fallback for the case where
`~/docker-data` itself was deleted. Keep `images.txt` as the manifest; run
`docker save -o image-cache/<name>_<tag>.tar <image>` (`/` and `:` become `_`)
whenever you add an image so the tar cache stays in sync.

## Operating Rules
1. Never use `docker run` / `docker compose up` here — they always fail at libnetwork sandbox setup. Use the scripts above.
2. Containers share the host network namespace (no isolation); services reach each other via `127.0.0.1:<port>`.
3. No cgroup limits are enforced; storage driver is `vfs` (slow).
4. In compose files, `$VAR` is interpolated by compose — write `$$VAR` for a literal `$` in the container.
5. Keep `~/workspace/docker-fix/images.txt` updated with images that should auto re-pull after resets.
6. The 8 sandbox workarounds (keyring, ociVersion, cgroup, netns, sysctl, capabilities, capset, vfs) are handled by the wrapper + `nocapset.so`; see `references/workarounds.md` before modifying them.
