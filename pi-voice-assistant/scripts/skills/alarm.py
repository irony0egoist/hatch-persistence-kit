#!/usr/bin/env python3
"""闹钟/提醒技能。
set_alarm(timestamp, label) 写入 ~/stt/alarms.json；
守护进程 alarm_daemon.py 每分钟检查，到点调用 speak.py 播报。
cancel_all() 清空；list_all() 列出待办提醒。
"""
import json, os, time

ALARM_FILE = "/boot/firmware/stt-data/alarms.json"


def _load():
    if os.path.exists(ALARM_FILE):
        return json.load(open(ALARM_FILE))
    return []


def _save(alarms):
    json.dump(alarms, open(ALARM_FILE, "w"), ensure_ascii=False, indent=1)


def set_alarm(timestamp, label):
    alarms = _load()
    alarms.append({"ts": timestamp,
                   "label": label,
                   "at": time.strftime("%m-%d %H:%M", time.localtime(timestamp))})
    alarms.sort(key=lambda a: a["ts"])
    _save(alarms)
    return "好的，%s提醒你：%s" % (alarms[-1]["at"], label)


def list_all():
    now = time.time()
    alarms = [a for a in _load() if a["ts"] > now]
    _save(alarms)
    if not alarms:
        return "没有待办的提醒。"
    return "待办提醒：" + "；".join("%s，%s" % (a["at"], a["label"]) for a in alarms)


def cancel_all():
    _save([])
    return "已取消全部提醒。"


def pop_due():
    """守护进程用：取出到点的提醒并从文件删除。"""
    now = time.time()
    alarms = _load()
    due = [a for a in alarms if a["ts"] <= now]
    _save([a for a in alarms if a["ts"] > now])
    return due


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 2:
        print(set_alarm(float(sys.argv[1]), " ".join(sys.argv[2:])))
    else:
        print(list_all())
