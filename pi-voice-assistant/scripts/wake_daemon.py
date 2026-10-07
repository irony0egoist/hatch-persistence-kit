#!/usr/bin/env python3
"""小迪唤醒守护进程：常驻监听麦克风，Vosk 离线识别唤醒词“小迪”，
唤醒后闪灯+提示音，走完整语音流程（voice_chat.py），然后回到监听。
开机自启：systemd user service voice-wake.service
"""
import json, os, subprocess, sys, time

HOME = os.path.expanduser("~")
STT_DIR = os.path.join(HOME, "stt")
VENV_PY = os.path.join(STT_DIR, "venv", "bin", "python")
MODEL = os.path.join(STT_DIR, "vosk-model-small-cn-0.22")
MIC = "alsa_input.usb-SEEED_ReSpeaker_4_Mic_Array__UAC1.0_-00.mono-fallback"
RUNTIME = "/run/user/1000"
WAKE_WORD = "小迪"


def _led():
    import importlib.util
    spec = importlib.util.spec_from_file_location("led", os.path.join(STT_DIR, "led.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def _speak(text):
    import importlib.util
    spec = importlib.util.spec_from_file_location("speak", os.path.join(STT_DIR, "speak.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.speak(text)


def listen_loop():
    from vosk import Model, KaldiRecognizer
    if not os.path.isdir(MODEL):
        print("Vosk 模型未找到：%s" % MODEL, flush=True)
        sys.exit(1)
    model = Model(MODEL)
    # 关键词识别：只要“小迪”，灵敏度可调
    rec = KaldiRecognizer(model, 16000, json.dumps([WAKE_WORD], ensure_ascii=False))
    rec.SetWords(True)

    env = dict(os.environ, XDG_RUNTIME_DIR=RUNTIME)
    proc = subprocess.Popen(
        ["parecord", "-d", MIC, "--rate=16000", "--channels=1",
         "--format=s16le", "--raw"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        bufsize=0)
    print("小迪待命中…说“%s”唤醒我" % WAKE_WORD, flush=True)
    led = _led()
    try:
        while True:
            data = proc.stdout.read(4000)
            if not data:
                time.sleep(0.1)
                continue
            if rec.AcceptWaveform(data):
                res = json.loads(rec.Result())
                text = res.get("text", "")
                if WAKE_WORD in text:
                    print("唤醒！", flush=True)
                    on_wake(led)
    except KeyboardInterrupt:
        pass
    finally:
        proc.terminate()


def on_wake(led):
    """唤醒后：亮灯→提示音→跑完整流程→回监听。"""
    try:
        led.flash(2, (160, 32, 255))
    except Exception:
        pass
    # 提示音：播本地预存（零延迟，不调 Edge-TTS）
    env = dict(os.environ, XDG_RUNTIME_DIR=RUNTIME)
    subprocess.run(["paplay", os.path.join(STT_DIR, "zainne.mp3")],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # 跑一轮完整语音对话（录音8s→识别→技能→播报）
    env = dict(os.environ, XDG_RUNTIME_DIR=RUNTIME)
    subprocess.run([VENV_PY, os.path.join(STT_DIR, "voice_chat.py"), "8"],
                   env=env)
    print("回到监听…", flush=True)


def main():
    lock = "/tmp/wake_daemon.lock"
    if os.path.exists(lock):
        try:
            pid = int(open(lock).read().strip())
            os.kill(pid, 0)
            print("唤醒守护进程已在运行")
            return
        except Exception:
            pass
    with open(lock, "w") as f:
        f.write(str(os.getpid()))
    listen_loop()


if __name__ == "__main__":
    main()
