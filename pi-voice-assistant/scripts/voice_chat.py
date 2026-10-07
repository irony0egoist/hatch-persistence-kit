#!/usr/bin/env python3
"""树莓派语音助手 v3：录音 → STT → 意图识别 → 技能路由 → TTS → 播放
技能：闲聊 / 音乐 / 天气 / 新闻 / 备忘录 / 闹钟 / 翻译 / 汇率 / 故事 / 笑话 / 播客
"""
import os, sys, json, subprocess, asyncio, re, time

HOME = os.path.expanduser("~")
STT_DIR = os.path.join(HOME, "stt")
SKILLS = os.path.join(STT_DIR, "skills")
sys.path.insert(0, STT_DIR)
sys.path.insert(0, SKILLS)

MIC_SOURCE = "alsa_input.usb-SEEED_ReSpeaker_4_Mic_Array__UAC1.0_-00.mono-fallback"
RUNTIME_DIR = "/run/user/1000"
GROQ_MODEL = os.environ.get("GROQ_MODEL", "qwen/qwen3.8-27b")
TTS_VOICE = os.environ.get("TTS_VOICE", "zh-CN-XiaoxiaoNeural")
API = "https://api.groq.com/openai/v1"
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36"}

# 快速关键词预筛：命中才走 LLM 意图分类
SKILL_KW = re.compile(r"放|播放|暂停|继续|下一首|停止|别放|音乐|歌|大声|小声|音量|"
                      r"天气|气温|下雨|新闻|头条|详细|第.*条|记住|记一下|备忘|提醒|闹钟|叫我|"
                      r"翻译|英语|怎么说|美元|人民币|汇率|兑换|故事|笑话|播客|电台")


DATA_DIR = "/boot/firmware/stt-data"


def load_key():
    for p in (os.path.join(DATA_DIR, ".env"), os.path.join(STT_DIR, ".env")):
        if os.path.exists(p):
            for line in open(p):
                if line.startswith("GROQ_API_KEY="):
                    return line.strip().split("=", 1)[1]
    return os.environ.get("GROQ_API_KEY", "")


KEY = load_key()


def groq_post(path, payload, timeout=30):
    import urllib.request
    headers = {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"}
    headers.update(UA)
    req = urllib.request.Request(API + path, data=json.dumps(payload).encode(),
                                 headers=headers)
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def groq_text(system, user, max_tokens=300):
    d = groq_post("/chat/completions",
                  {"model": GROQ_MODEL,
                   "messages": [{"role": "system", "content": system},
                                {"role": "user", "content": user}],
                   "max_tokens": max_tokens})
    return d["choices"][0]["message"]["content"].strip()


def run(cmd, **kw):
    env = dict(os.environ, XDG_RUNTIME_DIR=RUNTIME_DIR)
    return subprocess.run(cmd, env=env, **kw)


def record(seconds, out="/tmp/speech.wav"):
    print("[1/4] 录音 %ds…请说话" % seconds, flush=True)
    run(["timeout", str(seconds + 2), "parecord", "-d", MIC_SOURCE,
         "--rate=16000", "--channels=1", out],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return out


def stt(wav_path):
    print("[2/4] 语音转文字…", flush=True)
    import urllib.request
    boundary = "----voicechat1234"
    with open(wav_path, "rb") as f:
        audio = f.read()
    head = ('--' + boundary + '\r\nContent-Disposition: form-data; name="file"; '
            'filename="s.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()
    mid = ('\r\n--' + boundary + '\r\nContent-Disposition: form-data; name="model"\r\n\r\n'
           'whisper-large-v3-turbo\r\n--' + boundary + '\r\n'
           'Content-Disposition: form-data; name="language"\r\n\r\nzh\r\n'
           '--' + boundary + '--\r\n').encode()
    headers = {"Authorization": "Bearer " + KEY,
               "Content-Type": "multipart/form-data; boundary=" + boundary}
    headers.update(UA)
    req = urllib.request.Request(API + "/audio/transcriptions",
                                 data=head + audio + mid, headers=headers)
    text = json.load(urllib.request.urlopen(req, timeout=60)).get("text", "").strip()
    print("    你说：" + text, flush=True)
    return text


INTENT_PROMPT = """你是中文语音助手的意图分类器兼闲聊回复器。只返回 JSON，不要多余文字。
意图列表：
- music.play(放歌，query=歌名/歌手) / music.pause / music.resume / music.stop / music.vol(delta=10或-10)
- weather.query(查天气)
- news.play(播新闻) / news.detail(新闻详情，index=第几条，如“详细说说第2条”)
- memo.add(记事，text=内容) / memo.list(查备忘) / memo.clear(清空)
- alarm.set(设提醒，label=事项，minutes=几分钟后 或 clock="HH:MM") / alarm.list(查提醒) / alarm.cancel(取消)
- translate(翻译，text=要翻译的内容，to=en或zh)
- currency(换算，amount=数字，from=USD/CNY/EUR/JPY/GBP/HKD，to=...)
- story(讲故事) / joke(讲笑话)
- podcast.play(播客，query=主题)
- l3.ask(复杂问题，需要上网查实时信息/比价/做攻略/翻个人记忆/多步骤推理，question=原话)
- chat(闲聊/知识问答，reply=100字内口语回复)
示例：{"intent":"chat","reply":"你好呀！有什么我可以帮你的？"}
注意：简单闲聊、知识问答走 chat；只有明显需要搜索、实时数据或复杂推理的才走 l3.ask
示例：{"intent":"music.play","query":"周杰伦 青花瓷"}
示例：{"intent":"alarm.set","minutes":10,"label":"喝水"}
示例：{"intent":"currency","amount":100,"from":"USD","to":"CNY"}"""


def classify_intent(text):
    try:
        raw = groq_text(INTENT_PROMPT, text, max_tokens=120)
        parsed = json.loads(raw[raw.index("{"):raw.rindex("}") + 1])
        return (parsed.get("intent", "chat"), parsed)
    except Exception as e:
        print("    意图识别失败，走闲聊：%s" % e, flush=True)
        return ("chat", {})


# L1 本地技能=闪1次(绿)，L2 Groq=闪2次(蓝)，L3 转交=闪3次(紫)
_L1 = ("music.", "weather.query", "news.", "memo.", "alarm.", "currency",
       "podcast.play")
_L2 = ("chat", "translate", "story", "joke")


def _flash_for_intent(intent):
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "led", os.path.join(STT_DIR, "led.py"))
        led = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(led)
        if intent == "l3.ask":
            led.flash(3)
        elif intent.startswith(_L2) or intent in _L2:
            led.flash(2)
        else:
            led.flash(1)
    except Exception:
        pass


def _mod(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, os.path.join(SKILLS, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def handle_music(intent, p):
    mu = _mod("music")
    if intent == "music.play":
        q = (p.get("query") or "").strip()
        if not q:
            return "你想听什么歌？"
        print("[音乐] 搜歌：" + q, flush=True)
        title = mu.play(q)
        short = title[:28] + "…" if len(title) > 28 else title
        return "正在播放" + short
    if intent == "music.pause":
        mu.pause(); return "已暂停"
    if intent == "music.resume":
        mu.resume(); return "继续播放"
    if intent == "music.stop":
        mu.stop(); return "已停止播放"
    if intent == "music.vol":
        mu.vol(p.get("delta", 10)); return "好"
    return ""


def handle_skill(intent, p, text):
    """非音乐技能。返回播报文案。"""
    if intent == "l3.ask":
        question = (p.get("question") or text).strip()
        try:
            run(["musegadget", "send-user-msg", "[PI-L3] " + question],
                capture_output=True, timeout=15)
            try:
                import importlib.util as _ilu
                _spec = _ilu.spec_from_file_location(
                    "led", os.path.join(STT_DIR, "led.py"))
                _led = _ilu.module_from_spec(_spec)
                _spec.loader.exec_module(_led)
                _led.solid(3)
            except Exception:
                pass
            return "这个问题有点复杂，我让 Duckiji 查一下，查到就告诉你。"
        except Exception as e:
            print("[L3] 发送失败：%s" % e, flush=True)
            return "转交失败，你直接在手机上问我吧。"
    if intent == "weather.query":
        return _mod("weather").get_weather()
    if intent == "news.play":
        return _mod("news").briefing()
    if intent == "news.detail":
        idx = p.get("index", 1)
        try:
            idx = int(idx)
        except Exception:
            idx = 1
        title, body = _mod("news").detail(idx)
        if not body:
            return title or "没抓到正文。"
        summary = groq_text(
            "你是新闻摘要员。把下面的新闻正文浓缩成100字内的中文口语摘要，只说重点，不要标题。",
            body, 200)
        return "这条新闻说的是：" + summary
    if intent == "memo.add":
        return _mod("memo").add(p.get("text") or text)
    if intent == "memo.list":
        return _mod("memo").list_all()
    if intent == "memo.clear":
        return _mod("memo").clear()
    if intent == "alarm.set":
        label = p.get("label") or "提醒"
        minutes = p.get("minutes")
        clock = p.get("clock")
        if minutes:
            ts = time.time() + minutes * 60
        elif clock:
            h, mi = map(int, clock.split(":"))
            now = time.localtime()
            ts = time.mktime((now.tm_year, now.tm_mon, now.tm_mday, h, mi, 0,
                              now.tm_wday, now.tm_yday, now.tm_isdst))
            if ts < time.time():
                ts += 86400
        else:
            return "你想什么时候提醒你？"
        # 确保守护进程在跑
        ensure_alarm_daemon()
        return _mod("alarm").set_alarm(ts, label)
    if intent == "alarm.list":
        return _mod("alarm").list_all()
    if intent == "alarm.cancel":
        return _mod("alarm").cancel_all()
    if intent == "translate":
        to = p.get("to", "en")
        src = p.get("text") or text
        target = "英语" if to == "en" else "中文"
        ans = groq_text(f"你是翻译，把用户的话翻成{target}，只返回译文。", src, 100)
        return f"{target}是：{ans}"
    if intent == "currency":
        try:
            return _mod("currency").convert(float(p.get("amount", 0)),
                                            p.get("from", "USD"), p.get("to", "CNY"))
        except Exception:
            return "汇率换算失败，换个说法试试。"
    if intent == "story":
        return groq_text("你是讲故事的人，给10个月大宝宝的父母讲一个100字内的温馨睡前小故事，中文口语化。",
                         "讲个睡前故事", 400)
    if intent == "joke":
        return groq_text("你讲一个简短好笑的中文笑话，50字内。", "讲个笑话", 150)
    if intent == "podcast.play":
        q = (p.get("query") or "热门").strip()
        print("[播客] 搜：" + q, flush=True)
        mu = _mod("music")
        title, url = _mod("podcast").search_podcast(q)
        mu.ipc("loadfile", url, "replace")
        short = title[:28] + "…" if len(title) > 28 else title
        return "正在播放播客" + short
    return ""


def ensure_alarm_daemon():
    """确保闹钟守护进程在运行。"""
    import socket
    lock = "/tmp/alarm_daemon.lock"
    running = False
    if os.path.exists(lock):
        try:
            pid = int(open(lock).read().strip())
            os.kill(pid, 0)
            running = True
        except Exception:
            pass
    if not running:
        env = dict(os.environ, XDG_RUNTIME_DIR=RUNTIME_DIR)
        subprocess.Popen([os.path.join(SKILLS, "alarm_daemon.py")],
                         env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("[闹钟] 守护进程已启动", flush=True)


def ask_llm(text):
    print("[3/4] 问 LLM…", flush=True)
    ans = groq_text("你是简洁的中文语音助手，回答100字以内，口语化。", text)
    print("    回答：" + ans, flush=True)
    return ans


async def tts_async(text, out="/tmp/reply.mp3"):
    print("[4/4] 合成语音…", flush=True)
    import edge_tts
    await edge_tts.Communicate(text, TTS_VOICE).save(out)
    return out


def main():
    seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 8
    if not KEY:
        print("缺少 GROQ_API_KEY")
        sys.exit(1)
    text = stt(record(seconds))
    if not text.strip():
        print("没听清，再试一次")
        return
    intent, params = classify_intent(text)
    print("    意图：" + intent, flush=True)
    _flash_for_intent(intent)
    if intent.startswith("music."):
        reply = handle_music(intent, params)
    elif intent == "chat":
        reply = params.get("reply") or ask_llm(text)
    else:
        reply = handle_skill(intent, params, text)
        if not reply:
            reply = params.get("reply") or ask_llm(text)
    mp3 = asyncio.run(tts_async(reply))
    print("[5/5] 播放…", flush=True)
    run(["paplay", mp3], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("done", flush=True)


if __name__ == "__main__":
    main()
