from __future__ import annotations

from crcut.detect import analyze
from crcut.media import probe

TOLERANCE = 1.0


def test_probe_reads_portrait_dimensions(fake_cr):
    video, labels = fake_cr
    meta = probe(video)
    assert (meta.width, meta.height) == (labels["width"], labels["height"])
    assert abs(meta.duration - labels["duration"]) < 0.5


def test_live_gate_excludes_loading_and_victory_screens(fake_cr):
    video, labels = fake_cr
    an = analyze(probe(video))
    want_start, want_end = labels["live"]

    assert abs(an.action_start - want_start) <= TOLERANCE
    assert abs(an.action_end - want_end) <= TOLERANCE


def test_highlights_land_on_the_hits(fake_cr):
    """Flash + camera shake mark the moments; nothing outside the match may win."""
    video, labels = fake_cr
    an = analyze(probe(video))
    assert an.highlights

    for moment in an.highlights:
        assert an.action_start <= moment <= an.action_end
    for hit in labels["hits"]:
        assert min(abs(hit - m) for m in an.highlights) <= 2.0, f"hit {hit} missed: {an.highlights}"


def test_signals_are_alive(fake_cr):
    video, _ = fake_cr
    an = analyze(probe(video))
    assert an.motion.max() > 0
    assert an.flash.max() > 0
    assert an.shake.max() > 0
    assert len(an.hype) == len(an.t)
