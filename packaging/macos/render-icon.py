#!/usr/bin/env python3
"""Generate H's macOS AppIcon.icns using pure Python PNG synthesis + iconutil."""

import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib


def write_png(path: Path, size: int, pixels: bytes):
    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    stride = size * 4
    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type 0 (None)
        raw.extend(pixels[y * stride : (y + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def render_icon(size: int) -> bytes:
    """Render a crisp macOS squircle badge with H's architectural monogram."""
    buf = bytearray(size * size * 4)
    # Inset slightly per Apple HIG macOS icon grid (~82% canvas).
    pad = size * 0.085
    inner = size - 2.0 * pad
    half = inner / 2.0
    cx = size / 2.0
    cy = size / 2.0

    # Superellipse exponent (macOS squircle approximation).
    n = 4.6

    # Monogram H coordinates in normalized [-1, 1] space inside the badge.
    bar_w = 0.165
    left_x0, left_x1 = -0.44, -0.44 + bar_w
    right_x0, right_x1 = 0.44 - bar_w, 0.44
    top_y, bot_y = -0.46, 0.46
    cross_y0, cross_y1 = -0.08, 0.08

    # Subtle accent dot on the right-upper rail signaling live harness status.
    dot_cx, dot_cy, dot_r = 0.56, -0.56, 0.075

    def sample_color(px: float, py: float):
        dx = (px - cx) / half
        dy = (py - cy) / half
        d = (abs(dx) ** n + abs(dy) ** n) ** (1.0 / n)
        if d > 1.0:
            return (0.0, 0.0, 0.0, 0.0)

        # Smooth anti-aliased edge
        edge_px = 1.5 / half
        alpha = min(1.0, max(0.0, (1.0 - d) / edge_px))

        # Deep ink slate gradient (#18181B -> #0F172A) with subtle top specular sheen
        t = (dy + 1.0) * 0.5
        r = 26.0 * (1.0 - t) + 12.0 * t
        g = 28.0 * (1.0 - t) + 18.0 * t
        b = 34.0 * (1.0 - t) + 28.0 * t

        # Subtle inner hairline border
        if d > 0.945:
            rim = min(1.0, (d - 0.945) / 0.04) * 0.22
            r += (255.0 - r) * rim
            g += (255.0 - g) * rim
            b += (255.0 - b) * rim

        # Crisp ivory H glyph (#F8FAFC)
        in_left = left_x0 <= dx <= left_x1 and top_y <= dy <= bot_y
        in_right = right_x0 <= dx <= right_x1 and top_y <= dy <= bot_y
        in_cross = left_x1 <= dx <= right_x0 and cross_y0 <= dy <= cross_y1
        if in_left or in_right or in_cross:
            r, g, b = 248.0, 250.0, 252.0

        # Warm amber status dot (#F59E0B)
        if math.hypot(dx - dot_cx, dy - dot_cy) <= dot_r:
            r, g, b = 245.0, 158.0, 11.0

        return (r, g, b, alpha)

    # 2x2 supersampling for crisp edges at every icon resolution.
    offsets = (0.25, 0.75)
    for y in range(size):
        row_off = y * size * 4
        for x in range(size):
            sr = sg = sb = sa = 0.0
            for oy in offsets:
                for ox in offsets:
                    cr, cg, cb, ca = sample_color(x + ox, y + oy)
                    sr += cr * ca
                    sg += cg * ca
                    sb += cb * ca
                    sa += ca
            sa /= 4.0
            idx = row_off + x * 4
            if sa > 1e-6:
                buf[idx] = min(255, int(round(sr / (4.0 * sa))))
                buf[idx + 1] = min(255, int(round(sg / (4.0 * sa))))
                buf[idx + 2] = min(255, int(round(sb / (4.0 * sa))))
                buf[idx + 3] = min(255, int(round(sa * 255.0)))
    return bytes(buf)


def build_icns(dest: Path):
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    with tempfile.TemporaryDirectory(prefix="h-icon-", dir="/private/tmp") as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        cache = {}
        for px, filename in sizes:
            if px not in cache:
                cache[px] = render_icon(px)
            write_png(iconset / filename, px, cache[px])
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(dest)], check=True)
    print(f"Generated {dest} ({dest.stat().st_size} bytes)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: render-icon.py /path/to/AppIcon.icns")
    build_icns(Path(sys.argv[1]))
