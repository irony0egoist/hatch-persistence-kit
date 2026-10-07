#!/usr/bin/env python3
"""备忘录技能：本地 JSON 存取。
add(text) 存一条；list_all() 返回全部。
"""
import json, os, time

MEMO_FILE = "/boot/firmware/stt-data/memos.json"


def _load():
    if os.path.exists(MEMO_FILE):
        return json.load(open(MEMO_FILE))
    return []


def _save(memos):
    json.dump(memos, open(MEMO_FILE, "w"), ensure_ascii=False, indent=1)


def add(text):
    memos = _load()
    memos.append({"time": time.strftime("%m-%d %H:%M"), "text": text})
    _save(memos)
    return "记下了：" + text


def list_all():
    memos = _load()
    if not memos:
        return "你还没有记任何事。"
    lines = ["你记了%d件事：" % len(memos)]
    for m in memos[-5:]:
        lines.append("%s，%s" % (m["time"], m["text"]))
    return "；".join(lines)


def clear():
    _save([])
    return "备忘录已清空。"


if __name__ == "__main__":
    import sys
    print(add(" ".join(sys.argv[1:])) if len(sys.argv) > 1 else list_all())
