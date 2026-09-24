# Runnable scripts for the `sandbox-docker` skill

Drop-in scripts implementing the skill. Copy them anywhere on your `PATH`
(or keep them in one dir) and `chmod +x` the shell scripts.

| File | What it does |
| ---- | ------------ |
| `docker-run.sh` | Run one container: `docker-run.sh [-v src:dst ...] <image> [cmd]` — via `docker pull/create/export` + `crun` direct-drive OCI bundle |
| `compose-run.sh` | Minimal compose runner (`up`/`down`), supports bind mounts and named volumes |
| `crun-nokeyring` | `crun` wrapper working around 8 sandbox restrictions (keyring, ociVersion, cgroup, netns, capset, …). Use as docker `default-runtime` or invoke directly |
| `nocapset.c` | `LD_PRELOAD` shim making `capset` a no-op (structures defined manually, no libcap headers needed). Build: `gcc -shared -fPIC -o nocapset.so nocapset.c` |

Quick start:

```bash
gcc -shared -fPIC -o nocapset.so nocapset.c
chmod +x docker-run.sh compose-run.sh crun-nokeyring
./docker-run.sh hello-world
```

See `../SKILL.md` and `../references/` for the full method.
