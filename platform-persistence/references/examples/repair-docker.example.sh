#!/bin/bash
# EXAMPLE — worked repair script from the author's environment (Muse sandbox).
# Follows platform-persistence/references/repair-script-template.sh.
# Paths (FIXDIR, data-root under ~) are the author's; adapt to your machine. No secrets embedded.
# repair-docker.sh — Docker 环境修复脚本（幂等，可重复运行）
# 用途：平台重置会清空 /etc、/usr（从基础镜像恢复），此脚本负责重建 Docker。
# 由平台级 cron 每 5 分钟调用一次。只打印做了什么，不打印任何密钥。
#
# 持久化设计：dockerd 的 data-root 指向 /home/hatch/docker-data（~ 下唯一跨越
# 重置的存储），因此镜像、容器、命名卷在重置后都还在，无需重建；下面的镜像
# 重拉逻辑只是兜底（比如用户误删了 docker-data）。
#
# 基础镜像自带：crun, python3, git, curl, wget
# 需要重建：docker-ce, docker-ce-cli, containerd.io, compose-plugin,
#           /usr/local/bin/crun-nokeyring, /etc/docker/daemon.json,
#           dockerd 服务
set -u

TAG="repair-docker"
FIXDIR="/home/hatch/workspace/docker-fix"
# 工具 deb 统一缓存在 ~/.tool-cache/<tool>/，安装走 .platform-repair/bin/install-cached-debs
DEBDIR="/home/hatch/.tool-cache/docker"
REPAIR_BIN="/home/hatch/.platform-repair/bin"
IMG_LIST="$FIXDIR/images.txt"
fixed=()
errors=0

log() { echo "[$TAG] $*"; }
mark_fixed() { fixed+=("$1"); log "FIXED: $1"; }
mark_error() { errors=$((errors+1)); log "ERROR: $*"; }

# --- 0. 代理环境透传给 systemd（dockerd 拉镜像需要） ---
if [ -n "${https_proxy:-}" ]; then
  systemctl set-environment https_proxy="$https_proxy" \
    http_proxy="${http_proxy:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
    HTTP_PROXY="${HTTP_PROXY:-}" no_proxy="${no_proxy:-}" NO_PROXY="${NO_PROXY:-}" \
    2>/dev/null || true
fi

# --- 1. Docker deb 包（统一走 ~/.tool-cache 缓存 + 通用安装器，不依赖 apt 源） ---
need_install=0
for bin in dockerd docker containerd; do
  command -v $bin >/dev/null 2>&1 || need_install=1
done
if [ "$need_install" = 1 ]; then
  log "docker 缺失，正在从缓存安装..."
  if "$REPAIR_BIN/install-cached-debs" "$DEBDIR" dockerd docker containerd; then
    mark_fixed "installed docker from cached debs"
  else
    mark_error "install docker from cached debs failed"
  fi
fi

# --- 2. crun wrapper ---
WRAPPER_SRC="$FIXDIR/crun-nokeyring"
WRAPPER_DST="/usr/local/bin/crun-nokeyring"
if [ -f "$WRAPPER_SRC" ]; then
  if [ ! -f "$WRAPPER_DST" ] || ! cmp -s "$WRAPPER_SRC" "$WRAPPER_DST"; then
    cp "$WRAPPER_SRC" "$WRAPPER_DST" && chmod +x "$WRAPPER_DST" \
      && mark_fixed "restored crun-nokeyring wrapper" \
      || mark_error "cannot restore crun wrapper"
  fi
else
  mark_error "wrapper source missing: $WRAPPER_SRC"
fi

# --- 3. daemon.json ---
# data-root 指向 ~ 下的持久目录：镜像/容器/卷跨越平台重置（见文件头注释）
DAEMON_JSON="/etc/docker/daemon.json"
WANT_JSON='{
  "storage-driver": "vfs",
  "iptables": false,
  "bridge": "none",
  "data-root": "/home/hatch/docker-data",
  "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "default-runtime": "crun-nokeyring",
  "runtimes": {
    "crun-nokeyring": {
      "path": "/usr/local/bin/crun-nokeyring"
    }
  }
}'
if [ ! -f "$DAEMON_JSON" ] || ! echo "$WANT_JSON" | cmp -s - "$DAEMON_JSON"; then
  mkdir -p /etc/docker
  echo "$WANT_JSON" > "$DAEMON_JSON" \
    && mark_fixed "wrote daemon.json" \
    || mark_error "cannot write daemon.json"
fi
# data-root 目录必须存在（~ 持久，但用户可能误删）
if [ ! -d /home/hatch/docker-data ]; then
  mkdir -p /home/hatch/docker-data && mark_fixed "created /home/hatch/docker-data" \
    || mark_error "cannot create /home/hatch/docker-data"
fi

# --- 4. dockerd 服务 ---
# 健康判断用功能信号优先，避免单一代理信号误报（如 systemctl 在沙箱中不可靠）：
# `docker info` 能通，或 dockerd 进程存在，都算健康。
docker_ok=0
docker info >/dev/null 2>&1 && docker_ok=1
pgrep -x dockerd >/dev/null 2>&1 && docker_ok=1
# 配置刚被改过（上面 FIXED 里有 daemon.json / wrapper），运行中的 dockerd 也要重启生效
config_changed=0
for f in "${fixed[@]}"; do
  case "$f" in
    "wrote daemon.json"|"restored crun-nokeyring wrapper") config_changed=1 ;;
  esac
done
if { [ "$docker_ok" = 0 ] || [ "$config_changed" = 1 ]; } && [ -f /lib/systemd/system/docker.service ]; then
  if [ "$(systemctl is-enabled docker 2>/dev/null)" != "enabled" ]; then
    systemctl enable docker 2>/dev/null && mark_fixed "enabled docker.service" || true
  fi
  # 配置变更后需要 daemon-reload + restart
  systemctl daemon-reload 2>/dev/null || true
  if systemctl restart docker 2>/dev/null; then
    sleep 5
    # 修复后必须用功能检查二次确认，避免"以为修好了"
    if docker info >/dev/null 2>&1; then
      mark_fixed "started dockerd (verified)"
    else
      mark_error "dockerd restarted but docker info still failing"
    fi
  else
    mark_error "cannot start dockerd"
  fi
elif [ "$docker_ok" = 0 ]; then
  mark_error "docker.service unit missing"
fi

# --- 5. 镜像重拉（兜底：data-root 在 ~ 下，正常情况下镜像都在，无需重拉） ---
# 只有当镜像真的缺失（比如 docker-data 被删）才从本地 tar / pull 恢复
if [ -f "$IMG_LIST" ] && command -v docker >/dev/null 2>&1; then
  # 等 daemon 就绪
  for i in $(seq 1 12); do
    docker info >/dev/null 2>&1 && break
    sleep 5
  done
  if docker info >/dev/null 2>&1; then
    while IFS= read -r img || [ -n "$img" ]; do
      # 去掉注释和空行
      img=$(echo "$img" | sed 's/#.*//' | xargs)
      [ -z "$img" ] && continue
      if ! docker image inspect "$img" >/dev/null 2>&1; then
        # 优先从本地 tar 缓存恢复（不依赖网络），没有才 pull
        tarname=$(echo "$img" | tr '/:' '__')
        tarfile="$HOME/workspace/docker-fix/image-cache/${tarname}.tar"
        if [ -f "$tarfile" ]; then
          log "loading $img from local cache..."
          if timeout 300 docker load -i "$tarfile" >/dev/null 2>&1 \
             && docker image inspect "$img" >/dev/null 2>&1; then
            mark_fixed "loaded $img from local tar"
            continue
          else
            log "local tar load failed for $img, falling back to pull"
          fi
        fi
        log "pulling $img..."
        if timeout 300 docker pull "$img" >/dev/null 2>&1; then
          mark_fixed "pulled $img"
        else
          mark_error "pull $img failed"
        fi
      fi
    done < "$IMG_LIST"
  else
    mark_error "dockerd not responding, skip image pull"
  fi
fi

# --- 汇总 ---
if [ "$errors" -gt 0 ]; then
  log "done with $errors error(s), repairs: ${fixed[*]:-none}"
  exit 1
elif [ "${#fixed[@]}" -eq 0 ]; then
  log "OK: all healthy"
else
  log "repairs made: ${fixed[*]}"
fi
exit 0
