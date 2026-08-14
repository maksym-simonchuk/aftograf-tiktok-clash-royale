"""Exports librosa beat grids for assets/music/*.mp3 as JSON for the Swift port,
copies the mp3s into ios/CRCut/Resources/music/, and pre-renders the 3 synth beat
presets (music.py::BEDS, exact grid, no librosa needed) to wav in the same folder.

Regenerate after assets/music/ changes:
    uv run python scripts/export_beatgrids.py

Needs the optional `beats` dependency group (librosa) -- see pyproject.toml.

Output: ios/CRCut/Resources/music/beatgrids.json
    {"fav": [<filename>, ...], "grids": {<filename>: [<beat second>, ...], ...}}
"fav" lists assets/music/fav/*.mp3 filenames (the track PlanKit/RenderKit should
prefer first); "grids" covers every copied file, real tracks and synth beds alike,
so the Swift side has one lookup table regardless of where a track came from.
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from crcut.music import BEDS, BPM, beat_grid, ensure_bed  # noqa: E402
from crcut.plan import VARIANT_SCALE, detect_beats  # noqa: E402

DEFAULT_DURATION = 42.0  # matches cli.py's --duration default
OUT_DIR = ROOT / "ios" / "CRCut" / "Resources" / "music"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    music_dir = ROOT / "assets" / "music"
    fav_dir = music_dir / "fav"
    fav = sorted(fav_dir.glob("*.mp3")) if fav_dir.is_dir() else []
    pool = sorted(music_dir.glob("*.mp3"))

    grids: dict[str, list[float]] = {}
    for track in fav + pool:
        shutil.copyfile(track, OUT_DIR / track.name)
        grids[track.name] = [round(t, 3) for t in detect_beats(track)]

    longest = DEFAULT_DURATION * max(VARIANT_SCALE)
    for i, bed in enumerate(BEDS):
        name = f"bed_{bed.name}_{int(BPM)}bpm.wav"
        dest = OUT_DIR / name
        dest.unlink(missing_ok=True)  # ensure_bed skips existing files; force a fresh render
        ensure_bed(dest, longest, i)
        grids[name] = beat_grid(longest)

    data = {"fav": [p.name for p in fav], "grids": grids}
    (OUT_DIR / "beatgrids.json").write_text(
        json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )

    # self-check: every promised file actually landed on disk
    for name in grids:
        assert (OUT_DIR / name).is_file(), f"missing {name}"
    print(f"wrote {len(grids)} beat grids ({len(fav)} fav) + {len(BEDS)} synth beds to {OUT_DIR}")


if __name__ == "__main__":
    main()
