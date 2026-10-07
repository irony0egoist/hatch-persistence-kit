#!/usr/bin/env python3
"""汇率技能：open.er-api.com 免费接口（无需 key），USD/CNY 为主。
convert(amount, from_cur, to_cur) 返回中文文案。
"""
import json, urllib.request

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36"}
_NAMES = {"USD": "美元", "CNY": "人民币", "EUR": "欧元", "JPY": "日元",
          "GBP": "英镑", "HKD": "港币"}


def _rates(base="USD"):
    url = "https://open.er-api.com/v6/latest/" + base
    req = urllib.request.Request(url, headers=UA)
    return json.load(urllib.request.urlopen(req, timeout=20))["rates"]


def convert(amount, from_cur, to_cur):
    from_cur, to_cur = from_cur.upper(), to_cur.upper()
    rates = _rates("USD")
    usd_amount = amount / rates[from_cur] if from_cur != "USD" else amount
    result = usd_amount * rates[to_cur]
    fn = _NAMES.get(from_cur, from_cur)
    tn = _NAMES.get(to_cur, to_cur)
    return f"{amount:g}{fn}约等于{result:.2f}{tn}。"


if __name__ == "__main__":
    print(convert(100, "USD", "CNY"))
