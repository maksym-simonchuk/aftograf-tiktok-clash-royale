"""ffprobe metadata, frame sampling into numpy, on-disk cache."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np

FFMPEG = shutil.which("ffmpeg") or "ffmpeg"
FFPROBE = shutil.which("ffprobe") or "ffprobe"

VIDEO_EXT = {".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi"}


class MediaError(RuntimeError):
    pass


@dataclass(frozen=True)
class Meta:
    path: str
    width: int
    height: int
    fps: float
    duration: float

    @property
    def aspect(self) -> float:
        return self.width / self.height


def _even(n: float) -> int:
    return max(2, int(round(n / 2)) * 2)


def _run(cmd: list[str], *, binary: bool) -> bytes:
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-6:]
        raise MediaError(f"{cmd[0]} failed ({proc.returncode}):\n" + "\n".join(tail))
    return proc.stdout if binary else proc.stdout


def find_videos(folder: Path) -> list[Path]:
    if folder.is_file():
        return [folder]
    return sorted(p for p in folder.iterdir() if p.suffix.lower() in VIDEO_EXT and not p.name.startswith("."))


def probe(path: Path) -> Meta:
    out = _run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_streams", "-show_format", "-of", "json", str(path)],
        binary=True,
    )
    data = json.loads(out)
    streams = data.get("streams") or []
    if not streams:
        raise MediaError(f"no video stream in {path}")
    st = streams[0]

    width, height = int(st["width"]), int(st["height"])
    if _rotation(st) % 180 == 90:
        width, height = height, width

    fps = _ratio(st.get("avg_frame_rate")) or _ratio(st.get("r_frame_rate")) or 30.0
    duration = float(st.get("duration") or data.get("format", {}).get("duration") or 0.0)
    if duration <= 0:
        raise MediaError(f"cannot determine duration of {path}")

    return Meta(path=str(path), width=width, height=height, fps=fps, duration=duration)


def _rotation(stream: dict) -> int:
    for sd in stream.get("side_data_list") or []:
        if "rotation" in sd:
            return abs(int(round(float(sd["rotation"]))))
    tag = (stream.get("tags") or {}).get("rotate")
    return abs(int(round(float(tag)))) if tag else 0


def _ratio(value: str | None) -> float | None:
    if not value or "/" not in value:
        return None
    num, den = value.split("/")
    return float(num) / float(den) if float(den) else None


def _decode_gray(meta: Meta, vf: str, out_w: int, out_h: int) -> np.ndarray:
    cmd = [
        FFMPEG, "-v", "error", "-nostdin", "-i", meta.path,
        "-vf", vf, "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1",
    ]
    buf = _run(cmd, binary=True)
    frame = out_w * out_h
    if frame == 0 or len(buf) % frame:
        raise MediaError(
            f"raw size {len(buf)} not divisible by frame {out_w}x{out_h}; "
            "probe metadata likely wrong (rotation?)"
        )
    return np.frombuffer(buf, dtype=np.uint8).reshape(-1, out_h, out_w)


def sample_gray(meta: Meta, fps: float = 10.0, width: int = 160) -> np.ndarray:
    """Whole-frame grayscale sample, shape (T, H, W)."""
    w = _even(width)
    h = _even(meta.height * w / meta.width)
    return _decode_gray(meta, f"fps={fps},scale={w}:{h},format=gray", w, h)


def cache_key(path: Path) -> str:
    st = path.stat()
    raw = f"{path.name}|{st.st_size}|{int(st.st_mtime)}"
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def cache_path(root: Path, path: Path, suffix: str) -> Path:
    d = root / ".crcut"
    d.mkdir(parents=True, exist_ok=True)
    return d / f"{cache_key(path)}{suffix}"
