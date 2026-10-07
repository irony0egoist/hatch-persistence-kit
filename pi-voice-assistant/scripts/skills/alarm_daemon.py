#!/home/pi/stt/venv/bin/python
"""闹钟守护进程：每 30 秒检查 alarms.json，到点用 speak.py 语音播报。
用 systemd --user 或 nohup 常驻。建议：加到开机自启。
"""
import os, sys, time

HOME = os.path.expanduser("~")
sys.path.insert(0, os.path.join(HOME, "stt", "skills"))
sys.path.insert(0, os.path.join(HOME, "stt"))

from alarm import pop_due  # noqa: E402


def main():
    # 确保单实例
    lock = "/tmp/alarm_daemon.lock"
    if os.path.exists(lock):
        try:
            with open(lock) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            print("守护进程已在运行")
            return
        except Exception:
            pass
    with open(lock, "w") as f:
        f.write(str(os.getpid()))

    # speak 模块
    import importlib.util
    spec = importlib.util.spec_from_file_location("speak", os.path.join(HOME, "stt", "speak.py"))
    speak_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(speak_mod)

    print("闹钟守护进程启动", flush=True)
    while True:
        try:
            for a in pop_due():
                msg = "提醒时间到：" + a["label"]
                print(msg, flush=True)
                speak_mod.speak(msg)
        except Exception as e:
            print("daemon error: %s" % e, flush=True)
        time.sleep(30)


if __name__ == "__main__":
    main()
