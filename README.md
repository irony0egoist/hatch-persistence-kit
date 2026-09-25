> 🚀 **一键安装 / One-line install**

```bash
curl -fsSL https://raw.githubusercontent.com/irony0egoist/hatch-persistence-kit/main/install.sh | bash
```

一条命令装好 `platform-persistence` 与 `sandbox-docker` 两个 skills（含下载、自检），装完即用。

---

> 🎁 **Muse 邀请码 / Invite code: `G5U1BM`**

快来看看你的个人 AI 智能体 Muse —— 加入后 48 小时内在「设置」里兑现邀请码，我们**分别获得 10 亿 Muse 词元**（可累积，每邀请 1 人双方各得 10 亿，最多 20 人）。

https://muse.ai/join

---

# hatch-persistence-kit

Skills and patterns for making programs and data survive platform VM resets —
on this platform `/etc`, `/usr`, and system users are wiped without warning
(sometimes several times a day) and only `~` persists.

## Contents

- `platform-persistence/` — the anti-reset framework, distilled into a reusable skill:
  1. inventory what a program needs (binaries, configs, units, data dirs),
  2. cache full install materials under `~/.tool-cache/<tool>/` (never rely on apt at repair time),
  3. write an idempotent repair script (`references/repair-script-template.sh`),
  4. test it (run → repair, run again → `OK`),
  5. schedule a 5-minute health-check cron,
  6. register the tool in the persistence inventory.
  `references/reset-mechanism.md` documents the reset behavior as actually measured.
- `sandbox-docker/` — run Docker containers inside a restricted sandbox where
  standard `docker run` fails (the daemon's libnetwork can't manage netns here).
  Uses `docker pull/create/export` + `crun` direct-drive OCI bundles, with
  dockerd's `data-root` moved under `~` so images, containers, and named volumes
  survive resets (only running processes don't — restart them afterwards).

## Design principles

1. Only `~` is durable — cache every installer and keep all state there.
2. Repair scripts are idempotent and self-verifying: judge health with two
   independent signals (never one proxy signal), rebuild only what's missing,
   re-verify functionally after any repair.
3. One subsystem per script/cron; silent when healthy, notify only on `FIXED`/`ERROR`.
4. Never store secrets (keys, tokens, credentials) in scripts, configs, or logs.

## Status

In daily use on a platform that resets multiple times per day. See each skill's
`SKILL.md` for usage details.
