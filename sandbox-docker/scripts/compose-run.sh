#!/bin/bash
# compose-run.sh: 在 Muse 沙箱中运行 docker compose 项目（crun 直驱版）
# 用法:
#   compose-run.sh up [-f compose.yaml] [service...]   # 启动 service（后台）
#   compose-run.sh down [-f compose.yaml]              # 停止全部
#   compose-run.sh ps                                  # 查看运行状态
#   compose-run.sh logs <service>                      # 看日志
#
# 原理: docker compose config --format json 解析 -> 每个 service 用 crun 直驱
# 支持: image, command, entrypoint, environment, env_file,
#        volumes(bind + 命名卷，命名卷数据在 ~/docker-data 下，跨越平台重置),
#        working_dir, depends_on
# 不支持/无意义: networks(共享宿主netns), ports(共享netns直接可达), restart 策略, healthcheck

set -e
STATE_DIR="/tmp/compose-run-state"
mkdir -p "$STATE_DIR"

COMPOSE_FILE="compose.yaml"
[[ -f "docker-compose.yaml" ]] && COMPOSE_FILE="docker-compose.yaml"
[[ -f "docker-compose.yml" ]] && COMPOSE_FILE="docker-compose.yml"

usage() {
    echo "用法: $0 {up|down|ps|logs} [-f compose.yaml] [service...]" >&2
    exit 1
}

CMD="$1"; shift || usage
ARGS=()
SERVICES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) COMPOSE_FILE="$2"; shift 2 ;;
        -*) echo "未知选项: $1" >&2; usage ;;
        *) SERVICES+=("$1"); shift ;;
    esac
done

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "错误: 找不到 $COMPOSE_FILE" >&2
    exit 1
fi

PROJECT=$(basename "$(cd "$(dirname "$COMPOSE_FILE")" && pwd)" | tr -c 'a-z0-9' '-' | tr 'A-Z' 'a-z')
STATE_FILE="$STATE_DIR/$PROJECT.json"

# ---------- down / ps / logs ----------
if [[ "$CMD" == "down" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        python3 - "$STATE_FILE" <<'PYEOF'
import json, sys, os, signal
with open(sys.argv[1]) as f: st = json.load(f)
for name, info in st.get("services", {}).items():
    pid = info.get("pid")
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            print(f"停止 {name} (pid {pid})")
        except ProcessLookupError:
            print(f"{name} 已退出")
        except PermissionError as e:
            print(f"停止 {name} 失败: {e}")
PYEOF
        rm -f "$STATE_FILE"
    else
        echo "没有运行中的 service"
    fi
    exit 0
fi

if [[ "$CMD" == "ps" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        python3 - "$STATE_FILE" <<'PYEOF'
import json, sys, os
with open(sys.argv[1]) as f: st = json.load(f)
print(f"{'SERVICE':<20} {'PID':<8} {'STATUS'}")
for name, info in st.get("services", {}).items():
    pid = info.get("pid")
    alive = False
    if pid:
        try: os.kill(pid, 0); alive = True
        except OSError: pass
    print(f"{name:<20} {pid or '-':<8} {'运行中' if alive else '已退出'}")
PYEOF
    else
        echo "没有运行中的 service"
    fi
    exit 0
fi

if [[ "$CMD" == "logs" ]]; then
    SVC="${SERVICES[0]:-}"
    [[ -z "$SVC" ]] && { echo "用法: $0 logs <service>" >&2; exit 1; }
    LOG="$STATE_DIR/$PROJECT-$SVC.log"
    [[ -f "$LOG" ]] && tail -50 "$LOG" || echo "没有 $SVC 的日志"
    exit 0
fi

[[ "$CMD" == "up" ]] || usage

# ---------- up ----------
echo "[解析 compose 文件...]" >&2
CONFIG_JSON=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null)
if [[ -z "$CONFIG_JSON" ]]; then
    echo "错误: compose 文件解析失败" >&2
    docker compose -f "$COMPOSE_FILE" config 2>&1 | head -5 >&2
    exit 1
fi

# 按 depends_on 拓扑排序，逐个启动
export COMPOSE_FILE
python3 - "$CONFIG_JSON" "${SERVICES[*]}" "$STATE_DIR" "$PROJECT" <<'PYEOF'
import json, sys, os, subprocess, time, signal

config = json.loads(sys.argv[1])
wanted = sys.argv[2].split() if sys.argv[2].strip() else []
state_dir, project = sys.argv[3], sys.argv[4]
services = config.get("services", {})

if wanted:
    unknown = [s for s in wanted if s not in services]
    if unknown:
        print(f"错误: 未知 service: {unknown}", file=sys.stderr); sys.exit(1)
    # 只启动指定的及其依赖
    needed = set()
    def add_deps(s):
        if s in needed: return
        needed.add(s)
        dep = services[s].get("depends_on", [])
        # depends_on 可能是 list[str] 或 dict
        deps = dep.keys() if isinstance(dep, dict) else (dep or [])
        for d in deps: add_deps(d)
    for s in wanted: add_deps(s)
    services = {k: v for k, v in services.items() if k in needed}

# 拓扑排序
order, visited, temp = [], set(), set()
def visit(s):
    if s in visited: return
    if s in temp: print(f"警告: 循环依赖 {s}", file=sys.stderr); return
    temp.add(s)
    dep = services[s].get("depends_on", [])
    deps = dep.keys() if isinstance(dep, dict) else (dep or [])
    for d in deps:
        if d in services: visit(d)
    temp.discard(s); visited.add(s); order.append(s)
for s in services: visit(s)

print(f"启动顺序: {' -> '.join(order)}", file=sys.stderr)
state_file = os.path.join(state_dir, f"{project}.json")
state = {"services": {}}
if os.path.exists(state_file):
    with open(state_file) as f: state = json.load(f)

SCRIPT = "/home/hatch/workspace/docker-fix/docker-run.sh"

for svc in order:
    cfg = services[svc]
    image = cfg.get("image")
    if not image:
        # build 场景：尝试 docker compose build
        print(f"[{svc}] 无 image，尝试 build...", file=sys.stderr)
        subprocess.run(["docker", "compose", "-f", os.environ.get("COMPOSE_FILE", ""),
                        "build", svc], check=False)
        image = cfg.get("image", f"{project}-{svc}")
    # 先确保镜像存在
    r = subprocess.run(["docker", "image", "inspect", image],
                       capture_output=True)
    if r.returncode != 0:
        print(f"[{svc}] 拉取镜像 {image}...", file=sys.stderr)
        subprocess.run(["docker", "pull", image], check=True)

    # 构造环境变量和 volume 参数，调用 docker-run 的底层逻辑
    # 这里直接复用 docker-run.sh 的导出+OCI逻辑，通过环境变量注入额外配置
    env = {}
    _env_raw = cfg.get("environment", [])
    if isinstance(_env_raw, dict):
        # config --format json 输出 dict 格式
        env.update({k: (v if v is not None else "") for k, v in _env_raw.items()})
    else:
        for e in _env_raw or []:
            if isinstance(e, str):
                k, _, v = e.partition("=")
                env[k] = v
            elif isinstance(e, dict):
                env.update({k: (v if v is not None else "") for k, v in e.items()})
    # env_file
    for ef in cfg.get("env_file", []) or []:
        p = ef if isinstance(ef, str) else ef.get("path")
        if p and os.path.exists(p):
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, _, v = line.partition("=")
                        env.setdefault(k.strip(), v.strip())

    volumes = []
    def _docker_root():
        r = subprocess.run(["docker", "info", "--format", "{{.DockerRootDir}}"],
                           capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else "/home/hatch/docker-data"
    def _named_volume_path(name):
        r = subprocess.run(["docker", "volume", "create", name],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"[{svc}] 创建命名卷 {name} 失败", file=sys.stderr)
            return None
        p = os.path.join(_docker_root(), "volumes", name, "_data")
        os.makedirs(p, exist_ok=True)
        return p
    for v in cfg.get("volumes", []) or []:
        if isinstance(v, str):
            # short syntax: [SOURCE:]TARGET[:MODE]，SOURCE 为路径则是 bind，否则是命名卷
            parts = v.split(":")
            if len(parts) >= 2:
                src = parts[0]
                if os.path.exists(src) or src.startswith(("/", ".", "~")):
                    volumes.append((os.path.abspath(os.path.expanduser(src)), parts[1]))
                else:
                    p = _named_volume_path(src)
                    if p: volumes.append((p, parts[1]))
            elif len(parts) == 1:
                print(f"[{svc}] 跳过匿名卷 {v}", file=sys.stderr)
        elif isinstance(v, dict):
            if v.get("type") == "bind":
                volumes.append((v["source"], v["target"]))
            elif v.get("type") == "volume":
                p = _named_volume_path(v["source"])
                if p: volumes.append((p, v["target"]))
            else:
                print(f"[{svc}] 跳过不支持的卷类型 {v}", file=sys.stderr)

    # command / entrypoint（compose 用 $$ 转义 $，config 输出保留 $$，这里还原）
    def unescape(s):
        return s.replace("$$", "$") if isinstance(s, str) else s
    cmd = cfg.get("command")
    if isinstance(cmd, str):
        import shlex; cmd = shlex.split(unescape(cmd))
    elif isinstance(cmd, list):
        cmd = [unescape(x) for x in cmd]
    entrypoint = cfg.get("entrypoint")
    if isinstance(entrypoint, str):
        import shlex; entrypoint = shlex.split(unescape(entrypoint))
    elif isinstance(entrypoint, list):
        entrypoint = [unescape(x) for x in entrypoint]
    workdir = cfg.get("working_dir")

    # 用一个 helper 脚本启动（后台），把 env/volumes 传进去
    import shlex as _shlex
    helper = os.path.join(state_dir, f"{project}-{svc}-start.sh")
    logf = os.path.join(state_dir, f"{project}-{svc}.log")
    with open(helper, "w") as f:
        f.write("#!/bin/bash\n")
        f.write(f"export CR_EXTRA_ENV={_shlex.quote(json.dumps(env))}\n")
        f.write(f"export CR_EXTRA_VOLUMES={_shlex.quote(json.dumps(volumes))}\n")
        if workdir:
            f.write(f"export CR_WORKDIR={_shlex.quote(workdir)}\n")
        if entrypoint:
            f.write(f"export CR_ENTRYPOINT={_shlex.quote(json.dumps(entrypoint))}\n")
        f.write(f"export COMPOSE_FILE={_shlex.quote(os.environ.get('COMPOSE_FILE', ''))}\n")
        parts = [_shlex.quote(SCRIPT), _shlex.quote(image)]
        if cmd:
            parts += [_shlex.quote(x) for x in cmd]
        f.write("exec " + " ".join(parts) + "\n")
    os.chmod(helper, 0o755)

    print(f"[{svc}] 启动中... (日志: {logf})", file=sys.stderr)
    # 检查是否已在运行
    old = state["services"].get(svc, {})
    if old.get("pid"):
        try:
            os.kill(old["pid"], 0)
            print(f"[{svc}] 已在运行 (pid {old['pid']})，跳过", file=sys.stderr)
            continue
        except OSError:
            pass
    with open(logf, "ab") as lf:
        p = subprocess.Popen(["/bin/bash", helper], stdout=lf, stderr=subprocess.STDOUT,
                             start_new_session=True)
    state["services"][svc] = {"pid": p.pid, "image": image}
    with open(state_file, "w") as f: json.dump(state, f)
    time.sleep(1)

print("全部启动完成。用 '$0 ps' 查看状态，'$0 logs <service>' 看日志，'$0 down' 停止。", file=sys.stderr)
PYEOF
