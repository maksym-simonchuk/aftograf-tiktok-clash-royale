"""Exports Python analyze()/build_plan() output as golden JSON for the Swift port.

Regenerate after any algorithm change in detect.py/plan.py:
    uv run python scripts/export_golden.py

Deterministic: re-running with no algorithm change produces byte-identical
files (the fixture video is cached by make_fake_cr.ensure, analyze/build_plan
are pure). XCTest reads these same files back (plan §5).
"""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests" / "fixtures"))

from make_fake_cr import ensure  # noqa: E402

from crcut.detect import analyze
from crcut.media import probe
from crcut.plan import PlanConfig, build_plan

GOLDEN = ROOT / "tests" / "golden"


def _dump(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def main() -> None:
    GOLDEN.mkdir(parents=True, exist_ok=True)
    video, labels = ensure(ROOT / "tests" / "fixtures" / "out")

    shutil.copyfile(video, GOLDEN / "fixture.mp4")
    shutil.copyfile(labels, GOLDEN / "labels.json")

    an = analyze(probe(video))
    _dump(GOLDEN / "analysis.json", {
        "t": [round(x, 6) for x in an.t.tolist()],
        "motion": [round(x, 6) for x in an.motion.tolist()],
        "flash": [round(x, 6) for x in an.flash.tolist()],
        "shake": [round(x, 6) for x in an.shake.tolist()],
        "hype": [round(x, 6) for x in an.hype.tolist()],
        "highlights": [round(x, 6) for x in an.highlights],
        "action_start": round(an.action_start, 6),
        "action_end": round(an.action_end, 6),
    })

    for mode, name in (("clips", "plan_clips.json"), ("montage", "plan_montage.json")):
        plan = build_plan([an], PlanConfig(mode=mode, target_duration=12.0))
        _dump(GOLDEN / name, plan.to_dict())

    print(f"wrote golden fixtures to {GOLDEN}")


if __name__ == "__main__":
    main()
