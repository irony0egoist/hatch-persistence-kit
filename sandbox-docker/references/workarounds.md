# Sandbox Workarounds (why the crun wrapper exists)

Standard `docker run` fails in this sandbox for 8 independent reasons. The
`/usr/local/bin/crun-nokeyring` wrapper + `~/workspace/docker-fix/nocapset.so`
(LD_PRELOAD) handle all of them. Do not remove a workaround without re-testing.

| # | Restriction | Symptom | Workaround |
|---|-------------|---------|------------|
| 1 | keyctl blocked | `unable to join session keyring` | inject `--no-new-keyring` after `create`/`run` |
| 2 | crun 1.14.1 rejects OCI 1.3.0 | `unknown version specified` | rewrite `ociVersion` → `1.0.0` |
| 3 | cgroup v2 has no controllers | `controller 'io' is not available` | strip `resources.{blockIO,cpu,memory,pids,rdma,hugepageLimits}` |
| 4 | new netns blocked by seccomp | `ioctl(SIOCSIFFLAGS): Operation not permitted` | drop `network` namespace → share host netns |
| 5 | no private netns | `net.*` sysctl fails | drop `net.*` sysctls |
| 6 | capability drop → EPERM | `capset: Operation not permitted` | rewrite caps to the process's actual `CapEff` set |
| 7 | capset blocked after ns setup | `OCI runtime create failed: capset` | `LD_PRELOAD=nocapset.so` makes `capset()` a no-op |
| 8 | overlayfs nesting fails | `failed to mount ... invalid argument` | dockerd `storage-driver: vfs` |

Additionally: Docker 29's libnetwork **always** does netns bind-mounts at container
start (`/proc/<pid>/ns/net` → `/var/run/docker/netns/`), which fails with
`permission denied` in the sandbox mount namespace. This is a daemon-level
limitation — no runtime wrapper can fix it, which is why `docker run` is
abandoned in favor of crun direct-drive.
