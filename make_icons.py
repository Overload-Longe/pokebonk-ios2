#!/usr/bin/env python3
"""生成 iOS App 图标（纯标准库，无 Pillow）。

iPhone: AppIcon60x60@2x(120) / @3x(180)
iPad:   AppIcon76x76@2x(152)
"""
import os
import struct
import zlib

BG = (18, 16, 26)
BALL_TOP = (226, 57, 70)
BALL_BOT = (241, 241, 244)
BAND = (26, 26, 30)

SS = 3


def write_png(path, w, h, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for px in row:
            raw.extend(px)
    comp = zlib.compress(bytes(raw), 9)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", comp)
    out += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


def sample(u, v):
    if abs(u) > 1 or abs(v) > 1:
        return BG + (255,)

    r = 0.86
    d = (u * u + v * v) ** 0.5
    if d > r:
        return BG + (255,)

    band = 0.075 * r / 0.86
    if abs(v) < band:
        base = BAND
    elif v < 0:
        base = BALL_TOP
    else:
        base = BALL_BOT

    if d < 0.30 * r:
        base = (245, 245, 248) if d < 0.22 * r else BAND

    hl = max(0.0, 1.0 - ((u + 0.28) ** 2 + (v + 0.30) ** 2) ** 0.5 / 0.62)
    if base != BAND and hl > 0:
        k = hl * 0.18
        base = tuple(min(255, int(c + (255 - c) * k)) for c in base)

    return base + (255,)


def render(size, out):
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(SS):
                for sx in range(SS):
                    ux = (x + (sx + 0.5) / SS) / size * 2 - 1
                    uy = (y + (sy + 0.5) / SS) / size * 2 - 1
                    c = sample(ux, uy)
                    for i in range(4):
                        acc[i] += c[i]
            n = SS * SS
            row.append(tuple(v // n for v in acc))
        rows.append(row)
    write_png(out, size, size, rows)
    print(f"  {os.path.basename(out):28s} {size}x{size}  {os.path.getsize(out)}B")


def main():
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Resources")
    os.makedirs(base, exist_ok=True)
    for name, size in [
        ("AppIcon60x60@2x.png", 120),
        ("AppIcon60x60@3x.png", 180),
        ("AppIcon76x76@2x.png", 152),
    ]:
        render(size, os.path.join(base, name))


if __name__ == "__main__":
    main()
