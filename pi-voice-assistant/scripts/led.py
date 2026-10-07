#!/usr/bin/env python3
"""ReSpeaker 4 Mic Array 灯控：flash(n) 闪 n 次。
颜色：L1 本地技能=绿，L2 Groq=蓝，L3 转交=紫。
"""
import time

_green = (0, 255, 0)
_blue = (0, 0, 255)
_purple = (160, 32, 255)

_colors = {1: _green, 2: _blue, 3: _purple}

_pr = None


def _ring():
    global _pr
    if _pr is None:
        from pixel_ring import pixel_ring
        pixel_ring.set_brightness(20)
        _pr = pixel_ring
    return _pr


def flash(times, color=None):
    """闪 times 次。失败时静默（不影响主流程）。"""
    try:
        ring = _ring()
        c = color or _colors.get(times, _green)
        for _ in range(times):
            ring.set_color(*c)
            time.sleep(0.35)
            ring.off()
            time.sleep(0.25)
    except Exception:
        pass


def solid(times):
    """常亮（用于 L3 处理中）。times 只决定颜色。"""
    try:
        _ring().set_color(*_colors.get(times, _purple))
    except Exception:
        pass


def off():
    try:
        _ring().off()
    except Exception:
        pass


if __name__ == "__main__":
    import sys
    flash(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
