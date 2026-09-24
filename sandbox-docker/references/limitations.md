# Limitations of compose-run.sh

`compose-run.sh` is a pragmatic substitute for `docker compose up`, not a full
reimplementation.

## Supported
`image`, `command`, `entrypoint`, `environment`, `env_file`, `volumes` (bind
mounts and named volumes), `working_dir`, `depends_on` (topological start order),
`$$` escape restored to `$` per compose semantics.

Named volumes are created via dockerd and mounted from
`<data-root>/volumes/<name>/_data` (under `~`, so they survive platform resets).
Anonymous volumes (`- /data` with no source) are still skipped.

## Not supported / no-ops
- `networks`: meaningless — all containers share the host netns.
- `ports`: meaningless — ports are directly reachable (no NAT).
- `restart` policies, `healthcheck`: not implemented.
- `build`: attempted via `docker compose build` if `image` is absent, but build
  output handling is minimal.

## Networking between services
All services share the host network namespace: service A reaches service B at
`127.0.0.1:<port>` (B must listen on `0.0.0.0`, not `127.0.0.1` — same thing here).
No DNS-based service discovery; use fixed ports.

## Container egress
Outbound traffic goes through the sandbox proxy. Proxy env vars are forwarded
into containers, but direct connections may still be restricted — treat
container networking as best-effort.
