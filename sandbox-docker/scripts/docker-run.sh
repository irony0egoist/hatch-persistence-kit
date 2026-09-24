#!/bin/bash
# docker-run.sh: 在受限沙箱中用 crun 直接运行 Docker 镜像
# 用法: docker-run.sh [-v|--volume <src>:<dst> ...] <image> [command...]
#   -v name:/dst      命名卷（dockerd 管理，数据在 <data-root>/volumes/<name>，跨越平台重置）
#   -v /host:/dst     bind mount（host 路径建议放在 ~ 下以跨越重置）
# 原理: docker pull/create/export 获取镜像文件系统 -> 构造 OCI bundle -> crun 运行
# 限制: 无 Docker 网络管理（容器共享宿主 netns），无 cgroup 资源限制

set -e

# --- 解析 -v / --volume 参数 ---
VOLUMES_JSON="[]"
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
    -*) echo "未知选项: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

IMAGE="$1"
shift || true

if [[ -z "$IMAGE" ]]; then
    echo "用法: $0 <image> [command...]" >&2
    exit 1
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
        for _e in _env:
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

echo "[3/4] 启动容器..." >&2
CONTAINER_ID="drun-$(date +%s)-$$"
/usr/local/bin/crun-nokeyring run --no-new-keyring --bundle "$WORKDIR" "$CONTAINER_ID"
echo "[4/4] 完成" >&2
