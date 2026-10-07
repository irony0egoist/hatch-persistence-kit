#!/usr/bin/env python3
"""音乐播放模块：yt-dlp 搜歌 + mpv 播放/控制（IPC）。
用法示例：
  ~/stt/venv/bin/python ~/stt/music.py play "周杰伦 青花瓷"
  ~/stt/venv/bin/python ~/stt/music.py pause|resume|stop|vol+|vol-
"""
import json, os, socket, subprocess, sys, time

SOCK = "/tmp/mpv-sock"
YTD = [os.path.expanduser("~/stt/venv/bin/yt-dlp"), "--no-warnings"]

def mpv_running():
    return os.path.exists(SOCK)

def ensure_mpv():
    if mpv_running(): return
    env = dict(os.environ, XDG_RUNTIME_DIR="/run/user/1000")
    subprocess.Popen(["mpv", "--idle=yes", f"--input-ipc-server={SOCK}",
                      "--no-video", "--really-quiet"],
                     env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(20):
        if mpv_running(): return
        time.sleep(0.25)
    raise RuntimeError("mpv 启动失败")

def ipc(*args):
    ensure_mpv()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.sendall((json.dumps({"command": list(args)}) + "\n").encode())
    s.settimeout(3)
    data = b""
    try:
        while b"\n" not in data:
            data += s.recv(4096)
    except socket.timeout:
        pass
    s.close()
    line = data.decode().split(chr(10))[0]
    return json.loads(line) if line.strip() else {}

def search_url(query, n=1):
    out = subprocess.run(YTD + ["-f", "bestaudio[ext=m4a]/bestaudio",
                                "--get-url", f"ytsearch{n}:{query}"],
                         capture_output=True, text=True, timeout=90)
    urls = [l for l in out.stdout.splitlines() if l.startswith("http")]
    if not urls: raise RuntimeError(f"没搜到：{query}\n{out.stderr[-200:]}")
    return urls

def search_title(query):
    out = subprocess.run(YTD + ["--get-title", f"ytsearch1:{query}"],
                         capture_output=True, text=True, timeout=90)
    return out.stdout.strip().splitlines()[0] if out.stdout.strip() else query

def play(query):
    url = search_url(query)[0]
    title = search_title(query)
    ipc("loadfile", url, "replace")
    return title

def pause(): ipc("set_property", "pause", True)
def resume(): ipc("set_property", "pause", False)
def stop(): ipc("stop")
def vol(delta):
    v = ipc("get_property", "volume").get("data", 70)
    ipc("set_property", "volume", max(0, min(130, v + delta)))

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "play":
        print("正在播放：" + play(" ".join(sys.argv[2:])))
    elif cmd == "pause": pause(); print("已暂停")
    elif cmd == "resume": resume(); print("继续播放")
    elif cmd == "stop": stop(); print("已停止")
    elif cmd == "vol+": vol(10); print("音量+")
    elif cmd == "vol-": vol(-10); print("音量-")
    elif cmd == "status":
        print(json.dumps({k: ipc("get_property", k).get("data") for k in
                          ["pause", "volume", "media-title"]}, ensure_ascii=False))
