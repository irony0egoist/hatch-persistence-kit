---
name: "pi_voice_assistant"
description: "Deploy and manage 小迪, a Chinese voice assistant on Raspberry Pi: offline wake word (Vosk), Groq Whisper STT + LLM, Edge-TTS, local skills (music/weather/news/alarm/memo), and L3 bridge to Muse. Use when setting up, updating, or troubleshooting the Pi voice assistant."
---

# Pi Voice Assistant（小迪）

## Purpose

在树莓派上部署和管理中文语音助手"小迪"：离线唤醒词 + 云端语音识别/大模型 + 本地技能，复杂问题可转交给 Muse（Duckiji）处理。

## Architecture

语音链路（完整流程）：

```
"小迪"（Vosk 离线唤醒）
  → 录音（parecord，16kHz 单声道）
  → Groq Whisper 中文 STT（whisper-large-v3-turbo）
  → Groq qwen 意图分类（qwen/qwen3.8-27b）
  → L1 本地技能 / L2 Groq 快问答 / L3 转交 Muse
  → Edge-TTS 合成（zh-CN-XiaoxiaoNeural）
  → 蓝牙音箱播放（paplay）
```

路由规则（详见 `references/architecture.md`）：

| 级别 | 触发 | 灯效 |
|------|------|------|
| L1 | 音乐/天气/新闻/提醒/备忘录/汇率/播客等确定性技能 | 绿灯闪 1 次 |
| L2 | 闲聊/翻译/故事/笑话等 Groq 快问答 | 蓝灯闪 2 次 |
| L3 | 价格/攻略/实时查询/个人记忆/多步推理 | 紫灯闪 3 次后常亮，播报完熄灭 |

## Tooling

| 脚本 | 一句话说明 |
|------|-----------|
| `scripts/wake_daemon.py` | 常驻唤醒守护进程：Vosk 离线监听"小迪"，唤醒后闪灯+播"在呢"提示音，调起 voice_chat.py |
| `scripts/voice_chat.py` | 主流程：录音 → STT → 意图分类 → 技能路由 → TTS → 播放 |
| `scripts/voice_chat_vad.py` | VAD 实验版：能量检测自动断句，说完停顿 1 秒即停录音（省 3~6 秒/轮） |
| `scripts/speak.py` | 通用播报工具：`python speak.py "文字"`，供主流程和闹钟共用 |
| `scripts/led.py` | ReSpeaker 灯控：`flash(n)` 闪 n 次，颜色按 L1/L2/L3 区分 |
| `scripts/bt-autoreconnect.sh` | 蓝牙音箱断线自动重连（cron 每 2 分钟跑） |
| `scripts/skills/music.py` | 音乐：yt-dlp 搜歌 + mpv IPC 播放/暂停/音量 |
| `scripts/skills/weather.py` | 天气：Open-Meteo 免费 API（无需 key） |
| `scripts/skills/news.py` | 新闻：RSS 头条播报 + 正文抓取浓缩 |
| `scripts/skills/alarm.py` + `alarm_daemon.py` | 提醒：JSON 存闹钟，守护进程每 30 秒检查到点播报 |
| `scripts/skills/memo.py` | 备忘录：本地 JSON 增删查 |
| `scripts/skills/currency.py` | 汇率：open.er-api.com 免费接口 |
| `scripts/skills/podcast.py` | 播客：中文播客 RSS + mpv 播放 |

## Setup

部署步骤概要（完整版见 `references/setup.md`）：

1. 系统依赖：`parecord`（pulseaudio-utils）、`mpv`、`yt-dlp`、Python 3 venv
2. 建 venv 并装：`vosk`、`edge_tts`
3. 下载 Vosk 中文小模型到 `~/stt/vosk-model-small-cn-0.22`
4. 写 `~/stt/.env`（或 `/boot/firmware/stt-data/.env`）：`GROQ_API_KEY=...`
5. 复制脚本到 `~/stt/`，技能到 `~/stt/skills/`
6. 安装 systemd user 服务（`systemd/` 目录）：`voice-wake.service`、`voice-alarm.service`
7. 蓝牙配对音箱并设为默认输出，加 cron 跑 `bt-autoreconnect.sh`
8. 预生成唤醒提示音 `~/stt/zainne.mp3`（"在呢"，本地秒播）

## Operating Rules

**硬约束（部署/更新时必须遵守）：**

1. **密钥管理**：Groq API key 只放在 `~/stt/.env`（权限 600）或 `/boot/firmware/stt-data/.env`，绝不硬编码进脚本，绝不提交到 Git。
2. **数据持久化**：`memos.json`、`alarms.json`、`.env` 放在 `/boot/firmware/stt-data/`（独立启动分区），根分区加 `sync` 挂载防断电损坏。详见 `references/setup.md`。
3. **Python 环境**：所有脚本必须用 `~/stt/venv/bin/python` 运行，系统 Python 缺依赖（如 edge_tts）。
4. **敏感信息**：蓝牙 MAC、Tailscale IP、token、订阅链接等不要提交到仓库；脚本中用占位符 `XX:XX:XX:XX:XX:XX` 或环境变量。
5. **Groq 代理**：Groq API 在中国直连被墙（403），必须走美国代理；Python 请求统一加浏览器 User-Agent（否则 Cloudflare 拦截）。
6. **音频环境**：播放/录音命令需 `XDG_RUNTIME_DIR=/run/user/1000` 环境变量（PipeWire）。
7. **L3 桥接**：复杂问题发 `[PI-L3] <问题>` 到主聊天，Muse 处理后 SSH 回树莓派播报。协议见 `references/l3-protocol.md`。
8. **更新策略**：改脚本后 `python3 -m py_compile` 验证语法再部署；改动 `wake_daemon.py` 后需重启 `voice-wake.service`。
