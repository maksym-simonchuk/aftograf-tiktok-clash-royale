"""The impact synthesised locally, used when assets/sfx/ is empty.

Same policy as the music bed: crcut downloads nothing. A punch on every hit is
what makes a montage read as edited rather than merely trimmed -- too basic to be
worth sourcing, so it is generated.

The level is baked into the sample, because the render mixes every cue through one
gain.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

SR = 44100


def impact(cache_dir: Path) -> Path:
    """Sub-boom plus a crack -- the hit lands in the chest and in the ears."""
    path = cache_dir / "sfx_impact.wav"
    if path.exists():
        return path
    t = _t(0.55)
    sweep = 42.0 + 160.0 * np.exp(-t * 26.0)  # pitch drop is what reads as weight
    boom = np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t * 7.0)
    crack = _rng().standard_normal(len(t)) * np.exp(-t * 55.0) * 0.35
    return _write(path, boom + crack, peak=0.95)


def _t(seconds: float) -> np.ndarray:
    return np.arange(int(seconds * SR)) / SR


def _rng() -> np.random.Generator:
    return np.random.default_rng(3)


def _write(path: Path, samples: np.ndarray, peak: float) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    samples = samples / max(np.abs(samples).max(), 1e-9) * peak
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes((samples * 32767).astype("<i2").tobytes())
    return path
