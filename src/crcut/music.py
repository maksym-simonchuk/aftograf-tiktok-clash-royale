"""A backing loop synthesised locally, used when assets/music/ is empty.

Trending TikTok audio is licensed and cannot be downloaded here -- and it is
better attached inside the TikTok app anyway, because that is where the
algorithmic boost for a trending sound lives. So crcut never fetches anything:
it plays whatever you dropped into assets/music/, or this chiptune bed.

Its BPM is known exactly, which makes the beat grid exact too -- no librosa, and
cuts land dead on the beat.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

SR = 44100
BPM = 140.0
BEAT = 60.0 / BPM
ROOTS = [110.00, 87.31, 130.81, 98.00]  # A2 F2 C3 G2 -- one chord per bar
VOICES = [0, 7, 12, 16]  # power-chord shape, sits over major and minor alike


def beat_grid(duration: float) -> list[float]:
    return [round(i * BEAT, 3) for i in range(int(duration / BEAT) + 1)]


def ensure_bed(path: Path, duration: float) -> Path:
    if path.exists():
        return path
    path.parent.mkdir(parents=True, exist_ok=True)

    bars = int(duration / (4 * BEAT)) + 2
    total = int(bars * 4 * BEAT * SR)
    mix = np.zeros(total, dtype=np.float64)
    rng = np.random.default_rng(7)

    for bar in range(bars):
        root = ROOTS[bar % len(ROOTS)]
        for eighth in range(8):
            at = int((bar * 4 + eighth / 2) * BEAT * SR)
            note = root * 2 ** (VOICES[eighth % len(VOICES)] / 12)
            _add(mix, at, _square(note * 4, BEAT / 2, decay=14.0) * 0.16)  # arpeggio
            _add(mix, at, _square(root, BEAT / 2, decay=7.0) * 0.22)  # bass
            if eighth % 2 == 0:
                _add(mix, at, _kick(BEAT * 0.9) * 0.9)
            if eighth in (2, 6):
                _add(mix, at, _clap(BEAT * 0.5, rng) * 0.35)

    mix = np.tanh(mix / max(np.abs(mix).max(), 1e-9) * 1.6) * 0.72
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes((mix * 32767).astype("<i2").tobytes())
    return path


def _add(mix: np.ndarray, at: int, sound: np.ndarray) -> None:
    end = min(at + len(sound), len(mix))
    mix[at:end] += sound[: end - at]


def _t(seconds: float) -> np.ndarray:
    return np.arange(int(seconds * SR)) / SR


def _square(freq: float, seconds: float, decay: float) -> np.ndarray:
    t = _t(seconds)
    return np.sign(np.sin(2 * np.pi * freq * t)) * np.exp(-t * decay)


def _kick(seconds: float) -> np.ndarray:
    t = _t(seconds)
    sweep = 45.0 + 85.0 * np.exp(-t * 32.0)
    return np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t * 9.0)


def _clap(seconds: float, rng: np.random.Generator) -> np.ndarray:
    t = _t(seconds)
    return rng.standard_normal(len(t)) * np.exp(-t * 26.0)
