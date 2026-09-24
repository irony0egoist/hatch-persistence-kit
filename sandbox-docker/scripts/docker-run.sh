#!/bin/bash
# docker-run.sh: 在受限沙箱中用 crun 直接运行 Docker 镜像
# 用法: docker-run.sh [-d] [-v|--volume <src>:<dst> ...] <image> [command...]
#       docker-run.sh -h | --help     查看完整帮助 (风格参考 docker 官方 --help)
#   -d, --detach  后台运行 (日志写入 <脚本目录>/logs/<容器名>.log, -d 须放在镜像名之前)
#   -v name:/dst      命名卷（dockerd 管理，数据在 <data-root>/volumes/<name>，跨越平台重置）
#   -v /host:/dst     bind mount（host 路径建议放在 ~ 下以跨越重置）
# 管理命令 (crun 封装):
#   docker-run.sh ps                  列出运行中的容器
#   docker-run.sh sh <name> [cmd...]  进容器开 shell (chroot 近似实现)
#   docker-run.sh stop <name>...      优雅停止 (SIGTERM, 10 秒后未退出则 SIGKILL)
#   docker-run.sh kill <name>...      立即杀掉 (SIGKILL)
#   docker-run.sh logs <name>         查看 -d 模式容器的日志
# 注: crun exec 在本沙箱不可用 (seccomp 禁止 setns 切命名空间), 故不封装;
#     需要进容器排查时, 请用前台模式运行 (前台 Ctrl+C 即退出)
# 原理: docker pull/create/export 获取镜像文件系统 -> 构造 OCI bundle -> crun 运行
# 限制: 无 Docker 网络管理（容器共享宿主 netns），无 cgroup 资源限制

set -e

CRUN_BIN="${CRUN_BIN:-crun}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

# --- 子命令: 管理已运行容器 (crun 封装) ---
# 注意: 子命令优先于同名镜像。如需运行名为 ps 的镜像, 请显式加 tag, 如: docker-run.sh ps:latest
print_help() {
  # 风格参考 docker 官方 --help: Usage + Options + Commands 分组
  cat <<'EOF'
Usage:  docker-run.sh [OPTIONS] IMAGE [COMMAND] [ARG...]
   or:  docker-run.sh ps
   or:  docker-run.sh sh CONTAINER [COMMAND...]
   or:  docker-run.sh stop CONTAINER [CONTAINER...]
   or:  docker-run.sh kill CONTAINER [CONTAINER...]
   or:  docker-run.sh logs CONTAINER

在受限沙箱中用 crun 直接运行 Docker 镜像 (替代沙箱中不可用的 docker run)。

Options:
  -d, --detach       后台运行容器并打印容器名 (日志: <脚本目录>/logs/<容器名>.log,
                     -d 须放在镜像名之前)
  -v, --volume list  挂载卷, 可多次指定。命名卷 (dockerd 管理, 跨越平台重置)
                     或主机路径 (建议放在 ~ 下以跨越重置)
  -h, --help         打印本帮助

Management commands (crun 封装, 无需直接调用 crun):
  ps                 列出容器
  sh CONTAINER …     进容器开 shell (chroot 近似实现, 非真正 exec; 无参数则进交互式 /bin/sh)
  stop CONTAINER …   优雅停止: 先 SIGTERM, 10 秒未退出则 SIGKILL
  kill CONTAINER …   立即停止: SIGKILL
  logs CONTAINER     查看 -d 模式容器的日志 (最后 100 行)

说明:
  * crun exec 在本沙箱不可用 (seccomp 禁止 setns); 要进容器用 sh 子命令,
    要完整交互环境请用前台模式运行
  * 容器共享宿主 netns (无网络隔离), 无 cgroup 资源限制
  * 沙箱可能在会话结束时回收容器 cgroup 导致孤儿进程, stop/kill 会自动清理
EOF
}
_crun_name_exists() {
  # $1 = 容器名: 是否在 crun list 中 (任意状态)
  $CRUN_BIN list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$1"
}
_crun_is_running() {
  # $1 = 容器名: 状态是否为 running
  $CRUN_BIN list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}' | grep -qx "$1"
}
_crun_cleanup_orphans() {
  # $1 = 容器名: 沙箱可能在会话结束时提前回收容器 cgroup, 此时 crun 判定 stopped
  # (甚至 delete 也报错), 但容器进程还活着成为孤儿、占着端口/CPU。
  # 处理: delete --force 清状态; 按 crun 记录的 init pid 找到容器 mount ns (容器必在
  # 独立 mnt ns; 因用 pivot_root, /proc/<pid>/root 恒为 / 不能做路径校验), 杀掉该 ns
  # 内所有进程; 再补杀可能残留的 crun supervisor。
  # 防 pid 复用误杀: 只动 mnt ns 与当前 shell 不同的进程。
  local _n="$1" _st _pid _mnt _self_mnt _p
  _st="$($CRUN_BIN state "$_n" 2>/dev/null)" || _st=""
  if [[ -n "$_st" ]]; then
    _pid="$(echo "$_st" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid') or '')" 2>/dev/null)"
    _bundle="$(echo "$_st" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('bundle') or '')" 2>/dev/null)"
  fi
  # plain delete 在此状态下可能报 "not in created or stopped state" 的怪错, 用 --force
  $CRUN_BIN delete --force "$_n" 2>/dev/null || true
  [[ -z "${_pid:-}" || ! -d "/proc/$_pid" ]] && return 0
  _mnt="$(readlink "/proc/$_pid/ns/mnt" 2>/dev/null)"
  _self_mnt="$(readlink /proc/self/ns/mnt 2>/dev/null)"
  if [[ -z "$_mnt" || "$_mnt" == "$_self_mnt" ]]; then
    return 0  # pid 已被宿主进程复用, 不动手
  fi
  echo "发现孤儿进程 (容器 $_n 的 cgroup 已被回收), 清理..." >&2
  for _p in /proc/[0-9]*/ns/mnt; do
    _p="${_p#/proc/}"; _p="${_p%/ns/mnt}"
    [[ "$_p" == "1" || "$_p" == "$$" ]] && continue
    [[ "$(readlink "/proc/$_p/ns/mnt" 2>/dev/null)" == "$_mnt" ]] || continue
    kill -9 "$_p" 2>/dev/null || true
  done
  # 补杀残留的 crun supervisor (宿主 ns, cmdline 形如 "crun run ... <容器名>")
  # 本进程 cmdline 为 "bash .../docker-run.sh kill <名>", 不含 "crun", 不会误杀自己
  for _p in $(pgrep -f "crun[^ ]* run .* $_n\$" 2>/dev/null); do
    kill -9 "$_p" 2>/dev/null || true
  done
  # 收掉 bundle 临时目录 (每次运行都是 mktemp 的新目录; 严格匹配路径防误删)
  case "${_bundle:-}" in
    /tmp/docker-run-*) rm -rf "$_bundle" 2>/dev/null || true ;;
  esac
}
case "${1:-}" in
  ps)
    $CRUN_BIN list
    exit 0
    ;;
  kill)
    shift
    [[ $# -eq 0 ]] && { echo "用法: $0 kill <容器名> [容器名...]" >&2; exit 1; }
    for _n in "$@"; do
      _crun_name_exists "$_n" || { echo "$_n 不存在" >&2; continue; }
      $CRUN_BIN kill "$_n" SIGKILL 2>/dev/null || true
      sleep 1
      _crun_cleanup_orphans "$_n"
      echo "$_n 已停止" >&2
    done
    exit 0
    ;;
  stop)
    shift
    [[ $# -eq 0 ]] && { echo "用法: $0 stop <容器名> [容器名...]" >&2; exit 1; }
    for _n in "$@"; do
      _crun_name_exists "$_n" || { echo "$_n 不存在" >&2; continue; }
      if ! _crun_is_running "$_n"; then
        echo "$_n 已是停止状态, 清理残留..." >&2
        _crun_cleanup_orphans "$_n"
        continue
      fi
      $CRUN_BIN kill "$_n" SIGTERM 2>/dev/null || true
      echo "已发送 SIGTERM 给 $_n, 等待退出 (最多 10 秒)..." >&2
      _stopped=0
      for _i in $(seq 1 10); do
        if ! _crun_is_running "$_n"; then _stopped=1; break; fi
        sleep 1
      done
      if [[ $_stopped -eq 0 ]]; then
        echo "$_n 10 秒未退出, 发送 SIGKILL..." >&2
        $CRUN_BIN kill "$_n" SIGKILL 2>/dev/null || true
        sleep 1
      fi
      _crun_cleanup_orphans "$_n"
      echo "$_n 已停止" >&2
    done
    exit 0
    ;;
  logs)
    shift
    [[ $# -eq 0 ]] && { echo "用法: $0 logs <容器名>" >&2; exit 1; }
    _lf="$LOG_DIR/$1.log"
    if [[ -f "$_lf" ]]; then
      tail -n 100 "$_lf"
    else
      echo "没有 $1 的日志 (只有用 -d 模式启动的容器才记录日志)" >&2
      exit 1
    fi
    exit 0
    ;;
  sh)
    # 近似 docker exec -it: crun exec 在本沙箱不可用 (seccomp 禁 setns),
    # 这里用 chroot 进容器文件系统开 shell。注意 shell 运行在宿主的
    # pid/mnt 命名空间里 (只换了 root), 网络本就共享故无差别; 日常排查够用。
    shift
    [[ $# -eq 0 ]] && { echo "用法: $0 sh <容器名> [命令...]" >&2; exit 1; }
    _n="$1"; shift
    _st="$($CRUN_BIN state "$_n" 2>/dev/null)" || { echo "$_n 不存在" >&2; exit 1; }
    _pid="$(echo "$_st" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid') or '')" 2>/dev/null)"
    _status="$(echo "$_st" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status') or '')" 2>/dev/null)"
    _mnt=""
    if [[ -n "${_pid:-}" && -d "/proc/$_pid" ]]; then
      _mnt="$(readlink "/proc/$_pid/ns/mnt" 2>/dev/null)"
    fi
    _self_mnt="$(readlink /proc/self/ns/mnt 2>/dev/null)"
    if [[ -z "$_mnt" || "$_mnt" == "$_self_mnt" ]]; then
      echo "错误: $_n 的主进程已不存在${_status:+ (状态: $_status)}" >&2
      exit 1
    fi
    [[ "$_status" != "running" ]] && echo "注意: $_n 状态为 $_status (cgroup 已被回收的孤儿), 仍可进入其文件系统" >&2
    [[ $# -eq 0 ]] && set -- /bin/sh
    exec chroot "/proc/$_pid/root" "$@"
    ;;
esac

# --- 解析 -v / --volume / -d 参数 ---
VOLUMES_JSON="[]"
DETACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--volume)
      VSPEC="${2:-}"; shift 2 || { echo "错误: -v 缺少参数" >&2; exit 1; }
      VSRC="${VSPEC%%:*}"; VDST="${VSPEC#*:}"
      if [[ -z "$VSRC" || -z "$VDST" || "$VSRC" == "$VSPEC" ]]; then
        echo "错误: -v 参数格式应为 <src>:<dst>，得到: $VSPEC" >&2; exit 1
      fi
      if [[ "$VSRC" == /* || "$VSRC" == .* || "$VSRC" == ~* ]]; then
        # bind mount：~ 展开，不存在则创建
        [[ "$VSRC" == ~* ]] && VSRC="${VSRC/#\~/$HOME}"
        mkdir -p "$VSRC" 2>/dev/null || { echo "错误: 无法创建 $VSRC" >&2; exit 1; }
        VSRC="$(cd "$VSRC" && pwd)"
      else
        # 命名卷：经 dockerd 创建（幂等），解析到 data-root 下的真实目录
        if ! docker volume create "$VSRC" >/dev/null 2>&1; then
          echo "错误: 无法创建命名卷 $VSRC（dockerd 是否正常？）" >&2; exit 1
        fi
        DROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /home/hatch/docker-data)"
        VSRC="$DROOT/volumes/$VSRC/_data"
        mkdir -p "$VSRC"
      fi
      VOLUMES_JSON="$(echo "$VOLUMES_JSON" | python3 -c "
import json,sys
v=json.load(sys.stdin); v.append([sys.argv[1], sys.argv[2]]); print(json.dumps(v))
" "$VSRC" "$VDST")"
      ;;
    --) shift; break ;;
    -d|--detach) DETACH=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    -*) echo "未知选项: $1 (试试 '$0 --help')" >&2; exit 1 ;;
    *) break ;;
  esac
done

IMAGE="$1"
shift || true

if [[ -z "$IMAGE" ]]; then
    echo "用法: $0 [-d] [-v <src>:<dst> ...] <image> [command...]" >&2
    echo "       $0 {ps|sh|stop|kill|logs} ..." >&2
    echo "试试 '$0 --help' 查看完整帮助" >&2
    exit 1
fi

# 容器名: 允许用 CR_CONTAINER_ID 环境变量预先指定 (-d 模式靠它让父进程知道名字)
CONTAINER_ID="${CR_CONTAINER_ID:-drun-$(date +%s)-$$}"

# --- 后台模式: nohup 重跑自己, 父进程只负责打印信息 ---
if [[ "$DETACH" == "1" ]]; then
    mkdir -p "$LOG_DIR"
    _log="$LOG_DIR/$CONTAINER_ID.log"
    # -v 卷已解析进 VOLUMES_JSON, 通过环境变量传给子进程 (子进程不再带 -v 参数)
    # 注意: "$@" 此时已不含镜像名 (解析时被 shift 掉了), 需把 "$IMAGE" 补回去
    # 必须用 setsid 建新会话, 否则 exec 会话结束时整个进程组会被 SIGTERM (nohup 只防 SIGHUP 不够)
    CR_CONTAINER_ID="$CONTAINER_ID" CR_EXTRA_VOLUMES="$VOLUMES_JSON" \
        setsid nohup "$0" "$IMAGE" "$@" </dev/null >"$_log" 2>&1 &
    echo "容器 $CONTAINER_ID 已在后台启动" >&2
    echo "日志: $_log" >&2
    for _i in $(seq 1 30); do
        if $CRUN_BIN list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CONTAINER_ID"; then
            echo "状态: 运行中" >&2
            echo "查看: $0 ps | 停止: $0 stop $CONTAINER_ID | 日志: $0 logs $CONTAINER_ID" >&2
            exit 0
        fi
        sleep 1
    done
    echo "状态: 30 秒内未确认运行, 请用 '$0 ps' 查看, 或看日志排查: $_log" >&2
    exit 0
fi

WORKDIR=$(mktemp -d /tmp/docker-run-XXXXXX)
trap "rm -rf $WORKDIR" EXIT

echo "[1/4] 导出镜像文件系统..." >&2
CID=$(docker create "$IMAGE" 2>/dev/null)
if [[ -z "$CID" ]]; then
    echo "错误: 无法创建容器，请先 docker pull $IMAGE" >&2
    exit 1
fi
mkdir -p "$WORKDIR/rootfs"
docker export "$CID" | tar -x -C "$WORKDIR/rootfs"
docker rm "$CID" >/dev/null 2>&1
# 注入宿主的 DNS 配置（容器共享宿主 netns，需要同样的 DNS）
cp /etc/resolv.conf "$WORKDIR/rootfs/etc/resolv.conf" 2>/dev/null || true
# 注入 hosts
cp /etc/hosts "$WORKDIR/rootfs/etc/hosts" 2>/dev/null || true
# compose 模式：工作目录
if [[ -n "$CR_WORKDIR" ]]; then
    mkdir -p "$WORKDIR/rootfs$CR_WORKDIR" 2>/dev/null || true
fi

# 获取镜像的默认 CMD/Entrypoint
IMG_JSON=$(docker image inspect "$IMAGE" 2>/dev/null)
ENTRYPOINT=$(echo "$IMG_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; ep=d['Config'].get('Entrypoint'); print(' '.join(ep) if ep else '')" 2>/dev/null || echo "")
CMD=$(echo "$IMG_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; c=d['Config'].get('Cmd'); print(' '.join(c) if c else '')" 2>/dev/null || echo "")

if [[ $# -gt 0 ]]; then
    ARGS_JSON=$(printf '%s\n' "$@" | python3 -c "import json,sys; print(json.dumps([l.rstrip(chr(10)) for l in sys.stdin]))")
else
    # 用镜像默认的 Entrypoint+Cmd
    FULL_CMD="$ENTRYPOINT $CMD"
    ARGS_JSON=$(python3 -c "import json,shlex; print(json.dumps(shlex.split('''$FULL_CMD''')))")
fi
if [[ "$ARGS_JSON" == "[]" ]]; then
    ARGS_JSON='["/bin/sh"]'
fi

echo "[2/4] 生成 OCI 配置..." >&2
# -v 指定的卷与 compose 传入的 CR_EXTRA_VOLUMES 合并后注入 OCI 配置
if [[ "$VOLUMES_JSON" != "[]" ]]; then
  if [[ -n "${CR_EXTRA_VOLUMES:-}" ]]; then
    VOLUMES_JSON="$(python3 -c "
import json,sys
a=json.load(sys.stdin); print(json.dumps(a+json.loads(sys.argv[1])))
" "$VOLUMES_JSON" <<<"$CR_EXTRA_VOLUMES")"
  fi
  export CR_EXTRA_VOLUMES="$VOLUMES_JSON"
  echo "  volumes: $VOLUMES_JSON" >&2
fi
WORKDIR_ESC=$(echo "$WORKDIR" | sed 's/\//\\\//g')
python3 - "$WORKDIR" "$ARGS_JSON" <<'PYEOF'
import json, sys, os
workdir, args_json = sys.argv[1], sys.argv[2]
args = json.loads(args_json)

# 从 crun spec 生成基础配置
os.system(f"cd {workdir} && /usr/bin/crun spec >/dev/null 2>&1")
with open(f"{workdir}/config.json") as f:
    cfg = json.load(f)

cfg["ociVersion"] = "1.0.0"
cfg["root"]["path"] = f"{workdir}/rootfs"
cfg["root"]["readonly"] = False
cfg["process"]["args"] = args
cfg["process"]["terminal"] = False
cfg["process"]["noNewPrivileges"] = True
import os as _os  # compose 模式需要（提前 import）
# compose 模式：entrypoint 覆盖
_cr_ep = _os.environ.get("CR_ENTRYPOINT")
if _cr_ep:
    try:
        _ep = json.loads(_cr_ep)
        if _ep: cfg["process"]["args"] = _ep + cfg["process"]["args"]
    except Exception: pass
# compose 模式：工作目录
_cr_wd = _os.environ.get("CR_WORKDIR")
if _cr_wd: cfg["process"]["cwd"] = _cr_wd
# compose 模式：额外环境变量
_cr_env = _os.environ.get("CR_EXTRA_ENV")
if _cr_env:
    try:
        _extra = json.loads(_cr_env)
        _envd = {}
        for _e in cfg["process"].get("env", []):
            _k, _, _v = _e.partition("=")
            _envd[_k] = _v
        _envd.update(_extra)
        cfg["process"]["env"] = [f"{_k}={_v}" for _k, _v in _envd.items()]
    except Exception: pass
# compose 模式：bind mounts
_cr_vol = _os.environ.get("CR_EXTRA_VOLUMES")
if _cr_vol:
    try:
        for _src, _dst in json.loads(_cr_vol):
            cfg["mounts"].append({
                "destination": _dst, "type": "bind",
                "source": _src, "options": ["rbind", "rw"]
            })
    except Exception: pass
# 透传代理环境变量（沙箱出站需走代理）
_proxy_vars = ["http_proxy","https_proxy","all_proxy","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","no_proxy","NO_PROXY"]
_env = cfg["process"].get("env", [])
_existing = {e.split("=",1)[0] for e in _env}
for _k in _proxy_vars:
    _v = _os.environ.get(_k)
    if _v and _k not in _existing:
        _env.append(f"{_k}={_v}")
cfg["process"]["env"] = _env
# 共享宿主 netns（沙箱里建独立 netns 会被 seccomp 拦）
cfg["linux"]["namespaces"] = [ns for ns in cfg["linux"]["namespaces"] if ns.get("type") != "network"]
for k in [k for k in cfg.get("linux", {}).get("sysctl", {}) if k.startswith("net.")]:
    cfg["linux"]["sysctl"].pop(k, None)
# 去掉不可用的 cgroup 资源控制
for k in ["blockIO", "cpu", "memory", "pids", "rdma", "hugepageLimits"]:
    cfg.get("linux", {}).get("resources", {}).pop(k, None)
# 去掉 seccomp（简化，沙箱已有外层 seccomp）
cfg["linux"]["seccomp"] = None
# 用当前进程的全部 caps（避免 crun 的 capset 问题）
try:
    with open("/proc/self/status") as sf:
        cap_eff = 0
        for line in sf:
            if line.startswith("CapEff:"):
                cap_eff = int(line.split()[1], 16); break
    names = ["CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_DAC_READ_SEARCH","CAP_FOWNER","CAP_FSETID","CAP_KILL","CAP_SETGID","CAP_SETUID","CAP_SETPCAP","CAP_LINUX_IMMUTABLE","CAP_NET_BIND_SERVICE","CAP_NET_ADMIN","CAP_NET_RAW","CAP_IPC_LOCK","CAP_IPC_OWNER","CAP_SYS_MODULE","CAP_SYS_RAWIO","CAP_SYS_CHROOT","CAP_SYS_PTRACE","CAP_SYS_PACCT","CAP_SYS_ADMIN","CAP_SYS_BOOT","CAP_SYS_NICE","CAP_SYS_RESOURCE","CAP_SYS_TIME","CAP_SYS_TTY_CONFIG","CAP_MKNOD","CAP_LEASE","CAP_AUDIT_WRITE","CAP_AUDIT_CONTROL","CAP_SETFCAP","CAP_MAC_OVERRIDE","CAP_MAC_ADMIN","CAP_SYSLOG","CAP_WAKE_ALARM","CAP_BLOCK_SUSPEND","CAP_AUDIT_READ"]
    full = [names[i] for i in range(len(names)) if cap_eff & (1 << i)]
    if full:
        for k in ("bounding","effective","permitted"):
            cfg["process"]["capabilities"][k] = full
except Exception:
    pass

with open(f"{workdir}/config.json", "w") as f:
    json.dump(cfg, f)
print(f"  args: {args}", file=sys.stderr)
PYEOF

echo "[3/4] 启动容器... (容器名: $CONTAINER_ID)" >&2
/usr/local/bin/crun-nokeyring run --no-new-keyring --bundle "$WORKDIR" "$CONTAINER_ID"
echo "[4/4] 完成" >&2
