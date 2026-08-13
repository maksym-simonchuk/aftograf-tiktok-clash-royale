"""Synthetic 'fake Clash Royale' clip with events at known timestamps.

Lets the detector be developed and regression-tested without real footage:
  - a loading screen, then the match, then a victory screen -- the HUD only
    exists during the match, so the live gate must find exactly that stretch
  - arena: constantly moving shapes, plus a bright flash and a camera shake at
    each hit time (those are the moments the detector must pick)
  - HUD: a 'timer' block ticking every second and two static card hands
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

W, H, FPS = 540, 1170, 15
INTRO, MATCH, OUTRO = 3.0, 24.0, 3.0
DURATION = INTRO + MATCH + OUTRO
STRIP_H = int(H * 0.20)
ARENA_BOTTOM = int(H * 0.78)
HIT_TIMES = [INTRO + 4.0, INTRO + 11.0, INTRO + 19.0]


def draw_frame(t: float) -> Image.Image:
    if t < INTRO:
        return _screen((18, 60, 110), "loading")
    if t >= INTRO + MATCH:
        return _screen((190, 170, 40), "victory")
    return _match_frame(t)


def _screen(color: tuple[int, int, int], kind: str) -> Image.Image:
    """Loading/victory screens: no HUD, so the gate must exclude them."""
    img = Image.new("RGB", (W, H), color)
    d = ImageDraw.Draw(img)
    cy = H * 0.35 if kind == "loading" else H * 0.5
    d.ellipse([W * 0.25, cy - W * 0.25, W * 0.75, cy + W * 0.25], fill=(240, 240, 250))
    return img


def _match_frame(t: float) -> Image.Image:
    img = Image.new("RGB", (W, H), (24, 26, 40))
    d = ImageDraw.Draw(img)

    # camera shake on each hit, exactly like the game shakes on a heavy impact
    hit = next((c for c in HIT_TIMES if 0.0 <= t - c < 0.4), None)
    sx = math.sin((t - hit) * 90.0) * 14 if hit is not None else 0.0

    # --- arena: motion every frame
    for k in range(6):
        cx = W * 0.5 + math.sin(t * 1.7 + k) * W * 0.34 + sx
        span = ARENA_BOTTOM - STRIP_H - 120
        cy = STRIP_H + 60 + ((k * 90 + t * 70) % span)
        d.rectangle([cx - 24, cy - 24, cx + 24, cy + 24], fill=(60 + 30 * k, 200 - 20 * k, 120))

    if hit is not None and t - hit < 0.3:
        d.rectangle([0, STRIP_H, W, ARENA_BOTTOM], fill=(252, 250, 240))

    # --- static card hands (top and bottom), what the live gate keys on
    d.rectangle([0, ARENA_BOTTOM, W, H], fill=(30, 32, 52))
    for k in range(4):
        d.rectangle([20 + k * 130, H - 190, 20 + k * 130 + 110, H - 40], fill=(80 + k * 20, 90, 150))

    d.rectangle([0, 0, W, STRIP_H], fill=(38, 42, 66))
    for k in range(4):
        d.rectangle([20 + k * 130, 40, 20 + k * 130 + 110, 170], fill=(150, 90, 80 + k * 20))
    v = 40 + (int(t) * 37) % 180  # 'timer': new value every second
    d.rectangle([430, 190, 500, 225], fill=(v, v, v))

    return img


def render(out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    video = out_dir / "fake_cr.mp4"
    labels = out_dir / "fake_cr.labels.json"

    cmd = [
        "ffmpeg", "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "pipe:0",
        "-c:v", "libx264", "-crf", "10", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        str(video),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    assert proc.stdin is not None
    for n in range(int(DURATION * FPS)):
        proc.stdin.write(draw_frame(n / FPS).tobytes())
    proc.stdin.close()
    if proc.wait() != 0:
        raise RuntimeError("ffmpeg failed to build the fixture")

    labels.write_text(
        json.dumps(
            {
                "hits": HIT_TIMES,
                "live": [INTRO, INTRO + MATCH],
                "duration": DURATION,
                "width": W,
                "height": H,
            },
            indent=2,
        )
    )
    return video, labels


def ensure(out_dir: Path) -> tuple[Path, Path]:
    video, labels = out_dir / "fake_cr.mp4", out_dir / "fake_cr.labels.json"
    if video.exists() and labels.exists():
        return video, labels
    return render(out_dir)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=str(Path(__file__).parent / "out"))
    args = p.parse_args()
    v, lb = render(Path(args.out))
    print(f"{v}\n{lb}")
