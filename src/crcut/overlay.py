"""Caption images drawn with Pillow.

The local ffmpeg is built without libass/libfreetype, so `drawtext` and
`subtitles` do not exist -- text has to arrive as pixels. One tight RGBA PNG per
caption is enough: ffmpeg loops it as an extra input and overlays it for a
second or two, which costs nothing next to a full-length RGBA overlay track.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Black.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Impact.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]

FILL = (255, 255, 255, 255)
STROKE = (14, 14, 22, 255)


def find_font(assets: Path | None = None) -> str:
    """A font dropped into assets/fonts/ wins -- that is the point of the folder."""
    if assets:
        for path in sorted(assets.glob("*.tt[fc]")) + sorted(assets.glob("*.otf")):
            return str(path)
    for candidate in FONT_CANDIDATES:
        if Path(candidate).exists():
            return candidate
    raise FileNotFoundError("no usable font found -- drop a .ttf into assets/fonts/")


def render_caption(text: str, width: int, cache_dir: Path, font: str) -> Path:
    key = hashlib.sha1(f"{text}|{width}|{font}".encode()).hexdigest()[:16]
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / f"cap_{key}.png"
    if path.exists():
        return path

    max_w = int(width * 0.86)
    size = int(width * 0.115)
    while True:
        face = ImageFont.truetype(font, size)
        lines = _wrap(text, face, max_w)
        if size <= 28 or (len(lines) <= 3 and max(_width(face, ln) for ln in lines) <= max_w):
            break
        size = int(size * 0.88)

    stroke = max(2, size // 9)
    pad = stroke * 2 + 8
    line_h = int(size * 1.16)
    img = Image.new("RGBA", (max_w + 2 * pad, line_h * len(lines) + 2 * pad), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(lines):
        draw.text(
            (img.width // 2, pad + i * line_h), line, font=face, fill=FILL,
            stroke_width=stroke, stroke_fill=STROKE, anchor="ma",
        )

    # tight crop, so the caller can just centre the PNG and be done
    img.crop(img.getbbox() or (0, 0, img.width, img.height)).save(path)
    return path


def _wrap(text: str, face: ImageFont.FreeTypeFont, max_w: int) -> list[str]:
    lines: list[str] = []
    for word in text.split():
        if lines and _width(face, f"{lines[-1]} {word}") <= max_w:
            lines[-1] = f"{lines[-1]} {word}"
        else:
            lines.append(word)
    return lines or [text]


def _width(face: ImageFont.FreeTypeFont, text: str) -> int:
    box = face.getbbox(text)
    return box[2] - box[0]
