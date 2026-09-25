#!/usr/bin/env bash
#
# hatch-persistence-kit 一键安装脚本
#
# 用法（复制这一行执行即可）：
#   curl -fsSL https://raw.githubusercontent.com/irony0egoist/hatch-persistence-kit/main/install.sh | bash
#
# 做了什么：
#   1. 下载仓库（有 git 就 git clone，否则下载 tarball）
#   2. 把 platform-persistence / sandbox-docker 两个 skills 装到 ~/workspace/skills/
#   3. 把 docker-run.sh / compose-run.sh 及配套文件装到 ~/workspace/docker-fix/ 并设为可执行
#   4. 自检：文件齐全、脚本语法通过、docker-run.sh --help 可运行
#
# 全程只写 $HOME 下的目录，不需要 root / sudo，可重复执行（幂等）。
#
# 可选环境变量：
#   HPK_BRANCH        下载分支，默认 main
#   HPK_SKILLS_DIR    skills 安装目录，默认 $HOME/workspace/skills
#   HPK_DOCKERFIX_DIR 脚本安装目录，默认 $HOME/workspace/docker-fix
#   HPK_NO_CLEANUP=1  保留下载的临时目录，便于排查问题

set -euo pipefail

REPO="irony0egoist/hatch-persistence-kit"
BRANCH="${HPK_BRANCH:-main}"
SKILLS_DIR="${HPK_SKILLS_DIR:-$HOME/workspace/skills}"
DOCKERFIX_DIR="${HPK_DOCKERFIX_DIR:-$HOME/workspace/docker-fix}"

log()  { printf '[hpk-install] %s\n' "$*"; }
fail() { printf '[hpk-install] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1，请先安装它"
}

# ---- 1. 下载仓库 ----
TMPDIR="$(mktemp -d)"
if [ "${HPK_NO_CLEANUP:-0}" != "1" ]; then
    trap 'rm -rf "$TMPDIR"' EXIT
fi
SRC=""

if command -v git >/dev/null 2>&1; then
    log "用 git clone 下载 (branch=$BRANCH)..."
    git clone --depth 1 --branch "$BRANCH" "https://github.com/${REPO}.git" "$TMPDIR/repo" \
        || fail "git clone 失败，请检查网络或分支名"
    SRC="$TMPDIR/repo"
else
    need_cmd curl
    need_cmd tar
    need_cmd gzip   # tar -xz 解压需要
    log "未找到 git，下载 tarball (branch=$BRANCH)..."
    curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${BRANCH}" \
        | tar -xz -C "$TMPDIR" \
        || fail "tarball 下载或解压失败，请检查网络"
    # codeload 解压出的顶层目录形如 hatch-persistence-kit-main
    SRC="$(find "$TMPDIR" -maxdepth 1 -type d -name 'hatch-persistence-kit-*' | head -1)"
    [ -n "$SRC" ] || fail "tarball 解压后找不到顶层目录"
fi
log "仓库已下载到: $SRC"

# ---- 2. 安装 skills ----
mkdir -p "$SKILLS_DIR"
for skill in platform-persistence sandbox-docker; do
    [ -d "$SRC/$skill" ] || fail "仓库中缺少目录: $skill"
    rm -rf "$SKILLS_DIR/$skill"
    cp -a "$SRC/$skill" "$SKILLS_DIR/$skill"
    log "skill 已安装: $SKILLS_DIR/$skill"
done

# ---- 3. 安装 docker 脚本 ----
mkdir -p "$DOCKERFIX_DIR"
for f in docker-run.sh compose-run.sh crun-nokeyring nocapset.c README.md; do
    [ -f "$SRC/sandbox-docker/scripts/$f" ] || fail "仓库中缺少文件: sandbox-docker/scripts/$f"
    cp -a "$SRC/sandbox-docker/scripts/$f" "$DOCKERFIX_DIR/$f"
done
chmod +x "$DOCKERFIX_DIR/docker-run.sh" "$DOCKERFIX_DIR/compose-run.sh" "$DOCKERFIX_DIR/crun-nokeyring"
log "脚本已安装到: $DOCKERFIX_DIR"

# ---- 4. 自检 ----
log "开始自检..."
check=0

expect_file() {
    if [ -f "$1" ]; then
        log "  ok: $1"
    else
        log "  MISSING: $1"; check=1
    fi
}

expect_file "$SKILLS_DIR/platform-persistence/SKILL.md"
expect_file "$SKILLS_DIR/sandbox-docker/SKILL.md"
expect_file "$DOCKERFIX_DIR/docker-run.sh"
expect_file "$DOCKERFIX_DIR/compose-run.sh"

for sh in docker-run.sh compose-run.sh; do
    if bash -n "$DOCKERFIX_DIR/$sh"; then
        log "  ok: $sh 语法检查通过"
    else
        log "  FAIL: $sh 语法检查失败"; check=1
    fi
done

if "$DOCKERFIX_DIR/docker-run.sh" --help >/dev/null 2>&1; then
    log "  ok: docker-run.sh --help 可运行"
else
    log "  FAIL: docker-run.sh --help 运行失败"; check=1
fi

[ $check -eq 0 ] || fail "自检未通过，请检查上方 FAIL/MISSING 项"

# ---- 5. 完成 ----
log "安装成功，自检全部通过。"
printf '\n'
printf '下一步:\n'
printf '  - 查看 skill 说明: %s/platform-persistence/SKILL.md\n' "$SKILLS_DIR"
printf '  - 在沙箱里跑容器: %s/docker-run.sh hello-world\n' "$DOCKERFIX_DIR"
printf '  - 为自己的工具做抗重置: 参考 %s/platform-persistence/references/repair-script-template.sh\n' "$SKILLS_DIR"
printf '\n注意: docker-run.sh 依赖本机已装好的 docker engine 与 crun，\n'
printf '首次在新环境使用前，先按 sandbox-docker/SKILL.md 的"Rebuilding the stack"一节重建。\n'
