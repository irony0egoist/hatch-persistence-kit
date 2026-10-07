# 小迪架构详解

## 语音链路

```
┌─────────────┐
│  "小迪"      │  Vosk 中文小模型（vosk-model-small-cn-0.22）
│  离线唤醒    │  KaldiRecognizer 关键词识别，16kHz 单声道
└──────┬──────┘
       ▼
┌─────────────┐
│  提示反馈    │  紫灯闪 2 次 + 本地播放 zainne.mp3（"在呢"，零延迟）
└──────┬──────┘
       ▼
┌─────────────┐
│  录音       │  parecord，默认 8 秒（voice_chat_vad.py 用能量 VAD 自动断句）
└──────┬──────┘
       ▼
┌─────────────┐
│  STT        │  Groq Whisper whisper-large-v3-turbo，language=zh
└──────┬──────┘
       ▼
┌─────────────┐
│  意图分类    │  Groq qwen/qwen3.8-27b，返回 JSON {intent, params, reply?}
│             │  chat 意图顺带生成 reply，省一次 LLM 调用
└──────┬──────┘
       ▼
   ┌───┴───┐
   ▼   ▼   ▼
  L1  L2  L3（见下表）
   └───┬───┘
       ▼
┌─────────────┐
│  TTS 播放   │  Edge-TTS zh-CN-XiaoxiaoNeural → /tmp/reply.mp3 → paplay
└─────────────┘
```

## L1 / L2 / L3 路由表

### L1：本地技能（确定性执行）

| 意图 | 技能模块 | 说明 |
|------|---------|------|
| `music.play/pause/resume/stop/vol` | `skills/music.py` | yt-dlp 搜歌 + mpv IPC 控制 |
| `weather.query` | `skills/weather.py` | Open-Meteo，无需 key |
| `news.play` / `news.detail` | `skills/news.py` | RSS 头条；"详细说第 N 条"抓正文+Groq 浓缩 |
| `memo.add/list/clear` | `skills/memo.py` | 本地 JSON |
| `alarm.set/list/cancel` | `skills/alarm.py` | JSON + alarm_daemon.py 到点播报 |
| `currency` | `skills/currency.py` | open.er-api.com 免费接口 |
| `podcast.play` | `skills/podcast.py` | 中文播客 RSS + mpv |

### L2：Groq 快问答

| 意图 | 说明 |
|------|------|
| `chat` | 闲聊/知识问答，分类时直接生成 reply |
| `translate` | 中英互译 |
| `story` | 睡前故事（100字内） |
| `joke` | 笑话（50字内） |

### L3：转交 Muse（Duckiji）

| 意图 | 触发条件 |
|------|---------|
| `l3.ask` | 查价格、做攻略、实时信息、个人记忆、多步推理 |

L3 流程：树莓派执行 `musegadget send-user-msg "[PI-L3] <问题>"` 发到主聊天，
先语音播报"这个问题有点复杂，我让 Duckiji 查一下，查到就告诉你。"，
Muse 处理完 SSH 回树莓派执行 `speak.py "<100字口语答案>"` 播报。
完整协议见 `l3-protocol.md`。

## 灯效含义（ReSpeaker 4 Mic Array，USB 版，pixel_ring + pyusb）

| 场景 | 灯效 |
|------|------|
| 唤醒成功 | 紫灯闪 2 次 |
| L1 技能执行 | 绿灯闪 1 次 |
| L2 快问答 | 蓝灯闪 2 次 |
| L3 转交 | 紫灯闪 3 次 → 常亮（等待中）→ 播报结束熄灭 |

## 文件布局（树莓派 `~/stt/`）

```
~/stt/
├── voice_chat.py          # 主流程
├── voice_chat_vad.py      # VAD 实验版（未默认启用）
├── wake_daemon.py         # 唤醒守护进程
├── speak.py               # 通用播报工具
├── led.py                 # 灯控
├── bt-autoreconnect.sh    # 蓝牙重连（cron 每 2 分钟）
├── zainne.mp3             # 预生成的"在呢"提示音
├── .env                   # GROQ_API_KEY（600 权限；或放 /boot/firmware/stt-data/）
├── venv/                  # Python 虚拟环境
├── vosk-model-small-cn-0.22/  # Vosk 中文模型（约 66MB）
└── skills/
    ├── music.py  weather.py  news.py  podcast.py
    ├── memo.py  currency.py
    └── alarm.py  alarm_daemon.py

/boot/firmware/stt-data/   # 独立启动分区，断电不丢
├── .env                   # Groq key（优先读取）
├── memos.json
└── alarms.json

systemd user 服务：
├── voice-wake.service     # 唤醒守护进程（开机自启）
└── voice-alarm.service    # 闹钟守护进程（开机自启）
```

## 延迟拆解（优化基线）

| 环节 | 耗时 | 备注 |
|------|------|------|
| 唤醒识别 | ~1s | 本地 Vosk |
| "在呢"提示 | ~0.1s | 本地 mp3（原 Edge-TTS 需 2~5s，已优化） |
| 录音 | 8s 固定 | **最大瓶颈**；VAD 版可省 3~6s |
| Groq STT | ~2s | 走美国代理 |
| 意图分类+回答 | ~2s | 一次 LLM 调用完成 |
| Edge-TTS | 2~5s | 联网合成；可换本地 Piper（<1s，音质降一档） |
