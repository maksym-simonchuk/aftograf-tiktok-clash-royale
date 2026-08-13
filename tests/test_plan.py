from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from crcut.detect import Analysis
from crcut.media import Meta
from crcut.plan import TITLES, PlanConfig, build_plan


def make_analysis(name: str, duration: float, events: list[float]) -> Analysis:
    meta = Meta(path=f"/tmp/{name}.mp4", width=1080, height=2340, fps=30.0, duration=duration)
    t = np.arange(0.0, duration, 0.1)
    motion = 5.0 + np.sin(t) * 2.0
    flash = np.zeros_like(t)
    hype = sum((np.exp(-(((t - e) / 1.5) ** 2)) * 4.0 for e in events), np.zeros_like(t))
    return Analysis(
        meta=meta, t=t, motion=motion, flash=flash, shake=np.zeros_like(t), hype=hype,
        highlights=events, action_start=0.0, action_end=duration - 2.0,
    )


def test_montage_hits_target_duration_when_material_allows():
    events = [20.0 + 25.0 * i for i in range(10)]
    plan = build_plan([make_analysis("a", 300.0, events)], PlanConfig(target_duration=42.0))
    assert [g.name for g in plan.groups] == ["montage_v1", "montage_v2", "montage_v3"]
    assert abs(plan.groups[0].out_duration - 42.0) <= 3.0


def test_no_caption_is_reused_across_variants():
    events = [20.0 + 25.0 * i for i in range(10)]
    plan = build_plan([make_analysis("a", 300.0, events)], PlanConfig(target_duration=42.0))
    lines = [s.caption for g in plan.groups for s in g.segments[1:] if s.caption]
    assert len(lines) > 12
    assert len(set(lines)) == len(lines)


def test_adlibs_are_spoken_between_the_captions_and_never_repeat():
    events = [20.0 + 25.0 * i for i in range(10)]
    plan = build_plan([make_analysis("a", 300.0, events)], PlanConfig(target_duration=42.0))

    lines = [s.adlib for g in plan.groups for s in g.segments if s.adlib]
    assert len(lines) >= 3
    assert len(set(lines)) == len(lines)
    # spoken reactions live where nothing is written, so the two never overlap
    assert not any(s.adlib and s.caption for g in plan.groups for s in g.segments)


def test_variants_differ_in_length_and_opening():
    events = [20.0 + 25.0 * i for i in range(10)]
    plan = build_plan([make_analysis("a", 300.0, events)], PlanConfig(target_duration=42.0))
    durations = [g.out_duration for g in plan.groups]
    assert durations[1] < durations[0] < durations[2]
    assert len({g.segments[0].start for g in plan.groups}) == 3
    assert len({g.title for g in plan.groups}) == 3


def test_trimming_converges_on_an_extreme_target():
    """Regression: float dust in the trim loop used to hang the whole run."""
    events = [20.0 + 25.0 * i for i in range(10)]
    plan = build_plan([make_analysis("a", 300.0, events)], PlanConfig(target_duration=2.0))
    assert plan.groups[0].out_duration < 6.0


def test_short_material_yields_a_shorter_montage_never_padding():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0])]
    plan = build_plan(analyses, PlanConfig(target_duration=42.0))
    assert 0 < plan.groups[0].out_duration < 42.0


def test_montage_opens_with_the_best_moment():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0, 120.0, 160.0])]
    segments = build_plan(analyses, PlanConfig()).groups[0].segments

    assert segments[0].kind == "hook"
    assert segments[0].out_duration <= 1.5
    assert segments[0].score == max(s.score for s in segments)


def test_body_is_chronological_after_the_hook():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0, 120.0, 160.0])]
    body = build_plan(analyses, PlanConfig()).groups[0].segments[1:]
    starts = [s.start for s in body]
    assert starts == sorted(starts)


def test_plan_is_deterministic():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0, 120.0, 160.0])]
    first = build_plan(analyses, PlanConfig()).to_dict()
    second = build_plan(analyses, PlanConfig()).to_dict()
    assert first == second


def test_clips_mode_yields_one_group_per_highlight():
    analyses = [make_analysis("a", 90.0, [20.0, 45.0, 70.0])]
    plan = build_plan(analyses, PlanConfig(mode="clips"))

    assert len(plan.groups) == 3
    for group in plan.groups:
        assert 10.0 <= group.out_duration <= 25.0


def test_no_highlights_is_a_clear_error():
    with pytest.raises(ValueError):
        build_plan([make_analysis("a", 120.0, [])], PlanConfig())


def test_multiple_sources_are_indexed_and_ordered():
    analyses = [make_analysis("a", 90.0, [30.0]), make_analysis("b", 90.0, [40.0])]
    plan = build_plan(analyses, PlanConfig(target_duration=60.0))
    body = plan.groups[0].segments[1:]

    assert len(plan.sources) == 2
    assert {s.src for s in body} == {0, 1}
    assert [(s.src, s.start) for s in body] == sorted((s.src, s.start) for s in body)


def test_beat_snapping_moves_cuts_onto_beats():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0, 120.0])]
    beats = [round(i * 0.5, 3) for i in range(200)]
    plan = build_plan(analyses, PlanConfig(target_duration=40.0), grids=[beats])

    offsets = []
    for seg, start in plan.groups[0].timeline()[:-1]:
        cut = start + seg.out_duration
        offsets.append(min(abs(cut - b) for b in beats))
    assert max(offsets) < 0.05


def test_each_variant_snaps_to_the_grid_of_its_own_track():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0, 120.0])]
    grids = [[round(i * 0.5, 3) for i in range(400)],  # 120 bpm
             [round(i * 0.4, 3) for i in range(500)]]  # 150 bpm, off the other grid
    plan = build_plan(analyses, PlanConfig(target_duration=40.0, variants=2),
                      tracks=[Path("a.mp3"), Path("b.mp3")], grids=grids)

    assert [g.music for g in plan.groups] == ["a.mp3", "b.mp3"]
    for group, beats in zip(plan.groups, grids):
        cuts = [start + seg.out_duration for seg, start in group.timeline()[:-1]]
        assert max(min(abs(c - b) for b in beats) for c in cuts) < 0.05


def test_a_slow_track_still_gets_every_cut_on_a_beat():
    # 89 bpm: beats 0.674s apart, so a cut can sit 0.337s from the nearest one --
    # further than the fixed 0.30s window, which is how real tracks fell off the grid
    beats = [round(i * 0.674, 3) for i in range(300)]
    plan = build_plan([make_analysis("a", 180.0, [30.0, 75.0, 120.0])],
                      PlanConfig(target_duration=40.0, variants=1),
                      tracks=[Path("slow.mp3")], grids=[beats])

    cuts = [start + seg.out_duration for seg, start in plan.groups[0].timeline()[:-1]]
    assert max(min(abs(c - b) for b in beats) for c in cuts) < 0.05


def test_lang_flag_switches_copy():
    analyses = [make_analysis("a", 180.0, [30.0, 75.0, 120.0])]
    ru = build_plan(analyses, PlanConfig(lang="ru")).groups[0]
    en = build_plan(analyses, PlanConfig(lang="en")).groups[0]

    assert ru.title in TITLES["ru"] and en.title in TITLES["en"]
    assert "#рек" in ru.hashtags and "#fyp" in en.hashtags


def test_empty_analysis_raises():
    meta = Meta(path="/tmp/x.mp4", width=1080, height=1920, fps=30.0, duration=1.0)
    empty = Analysis(
        meta=meta, t=np.array([]), motion=np.array([]), flash=np.array([]),
        shake=np.array([]), hype=np.array([]),
        highlights=[], action_start=0.0, action_end=0.0,
    )
    with pytest.raises(ValueError):
        build_plan([empty], PlanConfig())
