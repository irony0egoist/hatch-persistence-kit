# 小迪从零部署

目标机器：Raspberry Pi 4（2GB+），Raspberry Pi OS 64-bit。

## 1. 系统依赖

```bash
sudo apt update && sudo apt install -y \
  pulseaudio-utils \  # parecord 录音
  mpv \               # 音乐/播客播放
  python3-venv python3-pip \
  bluetooth bluez     # 蓝牙音箱
```

`yt-dlp` 建议用 pip 装最新版：
```bash
~/stt/venv/bin/pip install yt-dlp
```

## 2. Python 虚拟环境

```bash
mkdir -p ~/stt/skills
python3 -m venv ~/stt/venv
~/stt/venv/bin/pip install vosk edge_tts
```

**注意**：所有脚本必须用 `~/stt/venv/bin/python` 运行，系统 Python 缺 `edge_tts` 等依赖。

## 3. Vosk 中文模型

```bash
cd ~/stt
# 约 66MB，网络不稳定时可分段下载
wget https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip
unzip vosk-model-small-cn-0.22.zip
```

## 4. Groq API Key

```bash
# 方式一：放 ~/stt（权限 600）
echo 'GROQ_API_KEY=你的key' > ~/stt/.env
chmod 600 ~/stt/.env

# 方式二（推荐）：放独立启动分区，断电/重刷不丢
sudo mkdir -p /boot/firmware/stt-data
echo 'GROQ_API_KEY=你的key' | sudo tee /boot/firmware/stt-data/.env
```

**Groq 免费 key 获取**：https://console.groq.com → 注册 → API Keys。
**注意**：Groq 在中国直连返回 403，必须走美国代理；Python 请求已内置浏览器 UA（防 Cloudflare 拦截）。

## 5. 部署脚本

```bash
# 从本仓库复制
cp scripts/*.py scripts/*.sh ~/stt/
cp scripts/skills/*.py ~/stt/skills/
chmod +x ~/stt/bt-autoreconnect.sh
```

## 6. 预生成唤醒提示音

```bash
~/stt/venv/bin/python - <<'EOF'
import asyncio, edge_tts
asyncio.run(edge_tts.Communicate("在呢", "zh-CN-XiaoxiaoNeural").save("/home/pi/stt/zainne.mp3"))
EOF
```

唤醒后播本地 mp3（零延迟），不调 Edge-TTS。

## 7. 蓝牙音箱配对

```bash
bluetoothctl
> power on
> scan on          # 找到音箱
> pair XX:XX:XX:XX:XX:XX
> trust XX:XX:XX:XX:XX:XX
> connect XX:XX:XX:XX:XX:XX
> exit
```

设为默认输出：
```bash
export XDG_RUNTIME_DIR=/run/user/1000
SINK=$(pactl list short sinks | grep -i bluez | cut -f2 | head -1)
pactl set-default-sink "$SINK"
```

加 cron 自动重连（把脚本里的 `SPEAKER_MAC` 换成实际地址）：
```bash
crontab -e
# */2 * * * * /home/pi/stt/bt-autoreconnect.sh
```

## 8. systemd 服务（开机自启）

```bash
mkdir -p ~/.config/systemd/user
cp systemd/voice-wake.service systemd/voice-alarm.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now voice-wake.service voice-alarm.service
```

验证：
```bash
systemctl --user is-active voice-wake.service voice-alarm.service
```

## 9. 防断电损坏（推荐）

SD 卡最怕突然断电。已验证有效的组合：

1. **数据放独立分区**：`memos.json`、`alarms.json`、`.env` 放 `/boot/firmware/stt-data/`（vfat 启动分区，挂载选项加 `uid=pi,gid=pi,umask=007`）。
2. **根分区加 `sync`**：`/etc/fstab` 里根分区挂载选项加 `sync`，写入直落盘，断电无脏数据。
3. **高频写入走内存盘**：`/tmp`、`/var/log`、`/var/tmp` 已是 tmpfs（默认 fstab 里有）。
4. **定期整卡备份**：`sudo dd if=/dev/mmcblk0 of=backup.img bs=4M`。

Overlay 只读方案因 initramfs/内核版本问题暂未采用；`sync` 方案已能防住断电损坏。

## 10. 验证

```bash
# 手动跑一轮
~/stt/venv/bin/python ~/stt/voice_chat.py 8
# 说"放一首青花瓷"，应听到音乐

# 唤醒测试：对麦克风说"小迪"，应听到"在呢"
```

## 常见问题

| 现象 | 排查 |
|------|------|
| 唤醒无反应 | `systemctl --user status voice-wake.service`；检查 Vosk 模型目录是否存在 |
| 唤醒了但没提示音 | 检查 `~/stt/zainne.mp3` 是否存在；`paplay` 需 `XDG_RUNTIME_DIR` |
| 没声音 | `pactl list short sinks` 看蓝牙 sink 在不在；`bt-autoreconnect.sh` 日志 `~/.bt-reconnect.log` |
| STT 报 403 | Groq key 无效或没走代理；检查 `.env` |
| TTS 很慢 | 正常（2~5s 联网合成）；可换本地 Piper |
| 录音 8 秒太长 | 换 `voice_chat_vad.py`（VAD 自动断句，需实测调参） |
