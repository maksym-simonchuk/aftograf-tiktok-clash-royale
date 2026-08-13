"""Visual highlight detection: motion / flash / camera-shake + a match-live gate.

Clash Royale draws no crown counter while a match runs -- the only persistent HUD
is the two card hands and the timer -- so highlights are read off the picture
itself: how much moves, how bright it flashes, and how hard the camera shakes
(the game shakes it on every heavy impact).

The gate exploits the other half of that fact: the HUD is pixel-stable for the
whole match and completely different on the loading and victory screens, so the
frames whose HUD rows match the match-time median are exactly the in-match ones.
That keeps intros and end screens out of the montage without any cut detection.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from .media import Meta, sample_gray


@dataclass(frozen=True)
class DetectConfig:
    sample_fps: float = 10.0
    sample_width: int = 240
    # arena band (fractions of frame height) -- between the two card hands
    arena_top: float = 0.24
    arena_bottom: float = 0.84
    # rows the match gate watches: the hands and name plates above/below the arena
    hud_top: float = 0.14
    hud_bottom: float = 0.85
    live_ratio: float = 2.5  # HUD dissimilarity over median*this => not in-match
    # highlight picking
    smooth: float = 1.5  # seconds
    min_gap: float = 6.0
    max_highlights: int = 6
    min_hype: float = 0.5


@dataclass
class Analysis:
    meta: Meta
    t: np.ndarray = field(repr=False)
    motion: np.ndarray = field(repr=False)
    flash: np.ndarray = field(repr=False)
    shake: np.ndarray = field(repr=False)
    hype: np.ndarray = field(repr=False)
    highlights: list[float]
    action_start: float
    action_end: float

    def to_dict(self) -> dict:
        return {
            "source": self.meta.path,
            "duration": round(self.meta.duration, 3),
            "highlights": [round(x, 3) for x in self.highlights],
            "action_start": round(self.action_start, 3),
            "action_end": round(self.action_end, 3),
        }


def analyze(meta: Meta, cfg: DetectConfig = DetectConfig()) -> Analysis:
    frames = sample_gray(meta, fps=cfg.sample_fps, width=cfg.sample_width)
    t = np.arange(len(frames), dtype=np.float64) / cfg.sample_fps

    motion, flash, shake = compute_signals(frames, cfg)
    start, end = live_window(frames, t, cfg)
    live = (t >= start) & (t <= end)
    hype = np.where(live, combine(motion, flash, shake), 0.0)

    return Analysis(
        meta=meta,
        t=t,
        motion=motion,
        flash=flash,
        shake=shake,
        hype=hype,
        highlights=find_highlights(t, hype, live, cfg),
        action_start=start,
        action_end=end,
    )


def compute_signals(
    frames: np.ndarray, cfg: DetectConfig
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Per-frame motion energy, bright-flash ratio and global camera shift."""
    n, h, _ = frames.shape
    arena = frames[:, int(h * cfg.arena_top) : int(h * cfg.arena_bottom), :].astype(np.float32)

    flash = (arena > 240).mean(axis=(1, 2))
    motion, shake = np.zeros(n), np.zeros(n)
    if n < 2:
        return motion, flash, shake

    window = cv2.createHanningWindow((arena.shape[2], arena.shape[1]), cv2.CV_32F)
    for i in range(1, n):
        motion[i] = np.abs(arena[i] - arena[i - 1]).mean()
        (dx, dy), _ = cv2.phaseCorrelate(arena[i - 1], arena[i], window)
        shake[i] = float(np.hypot(dx, dy))
    motion[0], shake[0] = motion[1], shake[1]
    return motion, flash, shake


def live_window(frames: np.ndarray, t: np.ndarray, cfg: DetectConfig) -> tuple[float, float]:
    """Longest stretch whose HUD rows look like the rest of the match."""
    n, h, _ = frames.shape
    if n < 8:
        return (float(t[0]), float(t[-1])) if n else (0.0, 0.0)

    hud = np.concatenate(
        [frames[:, : int(h * cfg.hud_top)], frames[:, int(h * cfg.hud_bottom) :]], axis=1
    ).astype(np.float32)
    reference = np.median(hud[n // 4 : 3 * n // 4], axis=0)
    dissimilarity = np.abs(hud - reference).mean(axis=(1, 2))

    live = dissimilarity < max(float(np.median(dissimilarity)) * cfg.live_ratio, 1.0)
    first, last = _longest_run(live)
    return float(t[first]), float(t[last])


def _longest_run(mask: np.ndarray) -> tuple[int, int]:
    best = (0, len(mask) - 1)
    best_len = 0
    start = None
    for i, on in enumerate([*mask, False]):
        if on and start is None:
            start = i
        elif not on and start is not None:
            if i - start > best_len:
                best_len, best = i - start, (start, i - 1)
            start = None
    return best


def combine(motion: np.ndarray, flash: np.ndarray, shake: np.ndarray) -> np.ndarray:
    return _z(motion) + 0.8 * _z(flash) + 1.2 * _z(shake)


def _z(x: np.ndarray) -> np.ndarray:
    """Robust z-score, clipped: one scene cut must not swamp a whole match."""
    median = float(np.median(x))
    mad = float(np.median(np.abs(x - median)))
    scale = 1.4826 * mad if mad > 1e-9 else (float(x.std()) or 1.0)
    return np.clip((x - median) / scale, -3.0, 6.0)


def find_highlights(
    t: np.ndarray, hype: np.ndarray, live: np.ndarray, cfg: DetectConfig
) -> list[float]:
    if len(t) < 2:
        return []

    fps = 1.0 / max(float(t[1] - t[0]), 1e-6)
    k = max(1, int(cfg.smooth * fps))
    smooth = np.convolve(hype, np.ones(k) / k, mode="same")

    picked: list[float] = []
    for i in np.argsort(smooth)[::-1]:
        if not live[i]:
            continue
        # the best in-match moment always makes the cut, however quiet the match was
        if picked and smooth[i] < cfg.min_hype:
            break
        moment = float(t[i])
        if all(abs(moment - p) >= cfg.min_gap for p in picked):
            picked.append(moment)
        if len(picked) >= cfg.max_highlights:
            break
    return sorted(round(p, 3) for p in picked)
