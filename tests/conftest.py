from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "fixtures"))

from make_fake_cr import ensure  # noqa: E402


@pytest.fixture(scope="session")
def fake_cr() -> tuple[Path, dict]:
    video, labels = ensure(Path(__file__).parent / "fixtures" / "out")
    return video, json.loads(labels.read_text())
