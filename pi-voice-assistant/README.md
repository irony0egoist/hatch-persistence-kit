# 小迪 · 树莓派中文语音助手

在树莓派上跑的中文语音对话助手：离线唤醒词 + Groq 免费语音识别/大模型 + Edge-TTS 中文语音，
复杂问题可转交给 Muse（Duckiji）处理。

## 功能

- 🎤 **离线唤醒**：说"小迪"即唤醒（Vosk 中文模型，本地识别，不断网也能用）
- 🎵 **音乐**：点歌/暂停/继续/音量（yt-dlp + mpv）
- 🌤 **天气**：Open-Meteo 免费接口
- 📰 **新闻**：RSS 头条播报，"详细说说第 N 条"抓正文浓缩
- ⏰ **提醒/闹钟**：到点语音播报
- 📝 **备忘录**：记事/查询/清空
- 💱 **汇率换算**、🌐 **中英翻译**、📻 **中文播客**、📖 **睡前故事**、😄 **笑话**
- 🧠 **L3 转交**：查价格/做攻略/实时信息等问题自动转给 Muse，答案回音箱播报
- 💡 **灯效反馈**：ReSpeaker 灯环按 L1/L2/L3 显示不同颜色
- 🔌 **防断电**：数据放独立分区 + 根分区 sync 挂载，突然断电不损坏系统

## 快速开始

```bash
# 1. 系统依赖
sudo apt install -y pulseaudio-utils mpv python3-venv bluetooth bluez

# 2. Python 环境
mkdir -p ~/stt/skills && python3 -m venv ~/stt/venv
~/stt/venv/bin/pip install vosk edge_tts yt-dlp

# 3. Vosk 中文模型（约 66MB）
cd ~/stt && wget https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip
unzip vosk-model-small-cn-0.22.zip

# 4. Groq API Key（https://console.groq.com 免费注册）
echo 'GROQ_API_KEY=你的key' > ~/stt/.env && chmod 600 ~/stt/.env

# 5. 部署脚本
cp scripts/*.py scripts/*.sh ~/stt/
cp scripts/skills/*.py ~/stt/skills/

# 6. 预生成唤醒提示音
~/stt/venv/bin/python -c "
import asyncio, edge_tts
asyncio.run(edge_tts.Communicate('在呢', 'zh-CN-XiaoxiaoNeural').save('/home/pi/stt/zainne.mp3'))"

# 7. 蓝牙音箱配对（把 XX 换成实际 MAC）
bluetoothctl trust XX:XX:XX:XX:XX:XX
bluetoothctl connect XX:XX:XX:XX:XX:XX

# 8. 开机自启
mkdir -p ~/.config/systemd/user
cp systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now voice-wake.service voice-alarm.service
```

详细步骤见 [references/setup.md](references/setup.md)。

## 架构

```
"小迪"（Vosk 离线唤醒）
  → 录音 → Groq Whisper 中文 STT
  → Groq qwen 意图分类
  → L1 本地技能 / L2 快问答 / L3 转交 Muse
  → Edge-TTS 合成 → 蓝牙音箱播放
```

| 级别 | 内容 | 灯效 |
|------|------|------|
| L1 | 音乐/天气/新闻/提醒/备忘录/汇率/播客 | 🟢 闪 1 次 |
| L2 | 闲聊/翻译/故事/笑话 | 🔵 闪 2 次 |
| L3 | 复杂问题转交 Muse | 🟣 闪 3 次后常亮 |

## 硬件

- Raspberry Pi 4（2GB+）
- ReSpeaker 4 Mic Array（USB 版，麦克风+灯环）
- 蓝牙音箱（实测：漫步者 EDIFIER M230）

## License

MIT
