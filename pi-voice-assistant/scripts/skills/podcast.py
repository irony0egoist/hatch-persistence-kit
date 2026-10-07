#!/usr/bin/env python3
"""播客技能：从中文播客 RSS 取最新一期，用 mpv 播放。
FEEDS 可自行增减。play_podcast(name=None) 搜名字或默认第一个。
"""
import re, urllib.request
from xml.etree import ElementTree as ET

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36"}

FEEDS = {
    # 名字: RSS 地址（示例，可换成你常听的）
    "商业就是这样": "https://feed.xyzfm.space/xxxxx",  # 占位，见下方说明
}


def _items(feed_url, n=3):
    req = urllib.request.Request(feed_url, headers=UA)
    data = urllib.request.urlopen(req, timeout=20).read()
    root = ET.fromstring(data)
    out = []
    for it in root.findall(".//item")[:n]:
        title = (it.findtext("title") or "").strip()
        enc = it.find("enclosure")
        url = enc.get("url") if enc is not None else ""
        if title and url:
            out.append((title, url))
    return out


def search_podcast(query):
    """用 yt-dlp 在 YouTube 搜中文播客，返回 (标题, 音频流地址)。"""
    import subprocess, os
    ytd = [os.path.expanduser("~/stt/venv/bin/yt-dlp"), "--no-warnings"]
    t = subprocess.run(ytd + ["--get-title", f"ytsearch1:{query} 播客"],
                       capture_output=True, text=True, timeout=90)
    u = subprocess.run(ytd + ["-f", "bestaudio[ext=m4a]/bestaudio", "--get-url",
                              f"ytsearch1:{query} 播客"],
                       capture_output=True, text=True, timeout=90)
    title = t.stdout.strip().splitlines()[0] if t.stdout.strip() else query
    urls = [l for l in u.stdout.splitlines() if l.startswith("http")]
    if not urls:
        raise RuntimeError("没搜到播客：" + query)
    return title, urls[0]


if __name__ == "__main__":
    import sys
    q = " ".join(sys.argv[1:]) or "商业访谈"
    print(search_podcast(q))
