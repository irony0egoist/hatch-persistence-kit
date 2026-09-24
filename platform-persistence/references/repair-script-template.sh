#!/bin/bash
# repair-<name>.sh — <one-line purpose> (idempotent, safe to re-run)
# Platform resets wipe /etc and /usr; this script rebuilds <name>.
# Invoked by cron every 5m. Prints ONLY the protocol lines below.
set -u

TAG="repair-<name>"          # <-- change me
fixed=()
errors=0

log() { echo "[$TAG] $*"; }
mark_fixed() { fixed+=("$1"); log "FIXED: $1"; }
mark_error() { errors=$((errors+1)); log "ERROR: $*"; }

# --- 0. proxy env to systemd (if the program needs egress) ---
if [ -n "${https_proxy:-}" ]; then
  systemctl set-environment https_proxy="$https_proxy" \
    http_proxy="${http_proxy:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
    HTTP_PROXY="${HTTP_PROXY:-}" no_proxy="${no_proxy:-}" NO_PROXY="${NO_PROXY:-}" \
    2>/dev/null || true
fi

# --- 1. binaries (cached .debs under ~/.tool-cache/<tool>/, installed via helper) ---
# Cache first (one-time, when adding the tool):
#   mkdir -p ~/.tool-cache/<tool> && cd ~/.tool-cache/<tool> && apt-get download <pkg>...
# if ! command -v <bin> >/dev/null 2>&1; then
#   /home/hatch/.platform-repair/bin/install-cached-debs /home/hatch/.tool-cache/<tool> <bin> \
#     && mark_fixed "installed <pkg> from cached debs" \
#     || mark_error "<pkg> install failed"
# fi

# --- 2. config files under /etc ---
# if [ ! -f /etc/<name>/config ]; then
#   mkdir -p /etc/<name>
#   cp ~/<area>/config-template /etc/<name>/config \
#     && mark_fixed "wrote /etc/<name>/config" \
#     || mark_error "cannot write config"
# fi

# --- 3. wrappers / helpers under /usr/local/bin ---
# if [ ! -x /usr/local/bin/<helper> ]; then
#   cp ~/<area>/<helper> /usr/local/bin/ && chmod +x /usr/local/bin/<helper> \
#     && mark_fixed "restored <helper>" \
#     || mark_error "cannot restore <helper>"
# fi

# --- 4. service running (multi-signal: never judge on one proxy signal alone) ---
# A single signal lies in sandboxes (e.g. `systemctl is-active` can say
# inactive while the process is alive). Judge health by a FUNCTIONAL signal
# (the program actually serving) OR an independent process signal; only act
# when all signals agree it's down; after acting, re-verify functionally.
# svc_ok=0
# <functional-check> >/dev/null 2>&1 && svc_ok=1   # e.g. `docker info`, `curl -sf localhost:port`, `(echo > /dev/tcp/127.0.0.1/22)`
# pgrep -x <daemon> >/dev/null 2>&1 && svc_ok=1
# if [ "$svc_ok" = 0 ]; then
#   systemctl enable --now <svc> 2>/dev/null
#   sleep 3
#   <functional-check> >/dev/null 2>&1 \
#     && mark_fixed "started <svc> (verified)" \
#     || mark_error "<svc> started but functional check still failing"
# fi

# --- summary (do not change) ---
if [ "$errors" -gt 0 ]; then
  log "done with $errors error(s), repairs: ${fixed[*]:-none}"
  exit 1
elif [ "${#fixed[@]}" -eq 0 ]; then
  log "OK: all healthy"
else
  log "repairs made: ${fixed[*]}"
fi
exit 0
