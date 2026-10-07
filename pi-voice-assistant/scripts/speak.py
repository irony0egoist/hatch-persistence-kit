#!/usr/bin/env python3
"""语音播报工具：文字 → Edge-TTS → 播放。供 voice_chat.py 和闹钟守护进程共用。
用法：~/stt/venv/bin/python ~/stt/speak.py "你好"
"""
import asyncio, os, sys, subprocess

HOME = os.path.expanduser("~")
TTS_VOICE = os.environ.get("TTS_VOICE", "zh-CN-XiaoxiaoNeural")
RUNTIME_DIR = "/run/user/1000"


async def _tts(text, out):
    import edge_tts
    await edge_tts.Communicate(text, TTS_VOICE).save(out)


def speak(text, out="/tmp/speak.mp3", play=True):
    asyncio.run(_tts(text, out))
    if play:
        env = dict(os.environ, XDG_RUNTIME_DIR=RUNTIME_DIR)
        subprocess.run(["mpv", "--no-video", "--really-quiet", out],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        import importlib.util as _ilu
        _spec = _ilu.spec_from_file_location("led", os.path.join(HOME, "stt", "led.py"))
        _led = _ilu.module_from_spec(_spec)
        _spec.loader.exec_module(_led)
        _led.off()
    except Exception:
        pass
    return out


if __name__ == "__main__":
    speak(" ".join(sys.argv[1:]) or "你好")
