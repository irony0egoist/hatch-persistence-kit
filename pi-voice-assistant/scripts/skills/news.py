#!/usr/bin/env python3
"""新闻技能：抓中文新闻 RSS 头条，返回播报文案。
headlines() 返回 [(标题, 链接)] 并缓存到 ~/stt/last_news.json，供 detail() 追问用。
detail(i) 抓第 i 条正文，返回前 2000 字纯文本（由调用方做 LLM 摘要）。
"""
import json, os, re, urllib.request
from xml.etree import ElementTree as ET

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36"}
FEEDS = [
    "https://www.people.com.cn/rss/politics.xml",  # 人民网时政
    "https://www.people.com.cn/rss/finance.xml",   # 人民网财经
    "https://www.people.com.cn/rss/society.xml",   # 人民网社会
]
CACHE = "/tmp/last_news.json"


def _clean(s):
    s = re.sub(r"<[^>]+>", "", s or "")
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def headlines(n=5):
    for url in FEEDS:
        try:
            req = urllib.request.Request(url, headers=UA)
            data = urllib.request.urlopen(req, timeout=20).read()
            root = ET.fromstring(data)
            items = root.findall(".//item")[:n] or root.findall(".//entry")[:n]
            out = []
            for it in items:
                t = _clean(it.findtext("title"))
                link = (it.findtext("link") or "").strip()
                if t and link:
                    out.append((t, link))
            if out:
                json.dump(out, open(CACHE, "w"), ensure_ascii=False)
                return out[:n]
        except Exception:
            continue
    return []


def briefing(n=5):
    items = headlines(n)
    if not items:
        return "新闻暂时抓不到，稍后再试。"
    titles = [t for t, _ in items]
    return ("今天的头条：" + "；".join(f"第{i+1}条，{t}" for i, t in enumerate(titles))
            + "。想听哪条的详情，就说比如“详细说说第2条”。")


def _article_text(url):
    req = urllib.request.Request(url, headers=UA)
    html = urllib.request.urlopen(req, timeout=20).read().decode("utf-8", "ignore")
    # 定位正文 div，取其中的 <p> 段落
    m = re.search(r"<div[^>]*rm_txt_con[^>]*>", html)
    seg = html[m.end():m.end() + 8000] if m else html
    paras = []
    for pm in re.findall(r"<p[^>]*>(.*?)</p>", seg, re.S):
        t = _clean(pm)
        if len(t) > 20:
            paras.append(t)
        if len("".join(paras)) > 2000:
            break
    return "".join(paras)[:2000]


def detail(index):
    """index 从 1 开始。返回 (标题, 正文前2000字)。"""
    if not os.path.exists(CACHE):
        return None, "先让我播一下新闻，才知道你说的是第几条。"
    items = json.load(open(CACHE))
    if not 1 <= index <= len(items):
        return None, f"我只播了{len(items)}条，没有第{index}条。"
    title, link = items[index - 1]
    try:
        return title, _article_text(link)
    except Exception:
        return title, ""


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        t, body = detail(int(sys.argv[1]))
        print(t, "\n", body[:300])
    else:
        print(briefing())
