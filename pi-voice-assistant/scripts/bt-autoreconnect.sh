#!/bin/bash
# bt-autoreconnect.sh — 漫步者 EDIFIER M230 蓝牙音箱断线自动重连
#
# 用法：放进树莓派 ~/stt/，由 pi 用户的 cron 每 2 分钟跑一次：
#   */2 * * * * /home/pi/stt/bt-autoreconnect.sh
# 一次性准备（Pi 恢复后执行一次即可）：
#   bluetoothctl trust XX:XX:XX:XX:XX:XX
#
# 行为：音箱已连接时完全静默；断开时尝试重连并记一行日志；
# 蓝牙栈不可用时记错退出，下一次 cron 会自动再试（自愈）。

set -u

SPEAKER_MAC="${SPEAKER_MAC:-XX:XX:XX:XX:XX:XX}"  # 通过环境变量或直接填入音箱 MAC
LOG="$HOME/.bt-reconnect.log"
MAX_LOG_BYTES=102400   # 100KB，超了就轮转，磁盘占用有界

log() {
  # 先轮转，避免日志无限增长
  if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG" "$LOG.old"
  fi
  echo "$(date '+%F %T') $*" >> "$LOG"
}

# 1) 蓝牙控制器在不在（服务没起 / 适配器掉了就直接退出等下次）
if ! bluetoothctl show 2>/dev/null | grep -q "^Controller"; then
  log "ERROR: 未找到蓝牙控制器（bluetooth 服务可能没起），跳过本次"
  exit 1
fi

# 2) 已连接就什么都不做
if bluetoothctl info "$SPEAKER_MAC" 2>/dev/null | grep -q "Connected: yes"; then
  exit 0
fi

# 3) 断开了，尝试重连
log "音箱未连接，尝试重连…"
if bluetoothctl connect "$SPEAKER_MAC" >/dev/null 2>&1; then
  log "重连成功"
  # 给 PipeWire 一点时间枚举出声卡，再把默认输出指过去
  # （防"连上了但没声音"——之前默认输出就是这只音箱）
  sleep 2
  SINK="$(pactl list short sinks 2>/dev/null | grep -i bluez | awk '{print $2}' | head -1)"
  if [ -n "$SINK" ]; then
    pactl set-default-sink "$SINK" 2>/dev/null && log "默认输出已指向 $SINK"
  fi
else
  log "重连失败（音箱可能没开机，2 分钟后重试）"
fi
