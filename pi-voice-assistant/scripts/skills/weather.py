#!/usr/bin/env python3
"""天气技能：Open-Meteo 免费 API（无需 key）。默认北京昌平沙河。
返回中文天气播报文案。
"""
import json, urllib.request

# 北京昌平沙河附近
LAT, LON = 40.09, 116.28
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36"}

WMO = {0: "晴", 1: "大部晴", 2: "多云", 3: "阴",
       45: "有雾", 48: "雾凇", 51: "毛毛雨", 53: "毛毛雨", 55: "毛毛雨",
       61: "小雨", 63: "中雨", 65: "大雨", 71: "小雪", 73: "中雪", 75: "大雪",
       80: "阵雨", 81: "阵雨", 82: "暴雨", 95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "雷阵雨伴冰雹"}


def get_weather():
    url = ("https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
           "&current=temperature_2m,weather_code,relative_humidity_2m"
           "&daily=temperature_2m_max,temperature_2m_min,weather_code"
           "&timezone=Asia%%2FShanghai" % (LAT, LON))
    req = urllib.request.Request(url, headers=UA)
    d = json.load(urllib.request.urlopen(req, timeout=20))
    cur = d["current"]
    today = d["daily"]
    w = WMO.get(cur["weather_code"], "")
    t = round(cur["temperature_2m"])
    hi = round(today["temperature_2m_max"][0])
    lo = round(today["temperature_2m_min"][0])
    return f"北京今天{w}，现在{t}度，最高{hi}度，最低{lo}度。"


if __name__ == "__main__":
    print(get_weather())
