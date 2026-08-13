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


def test_a_clip_bundles_up_to_three_events():
    analyses = [make_analysis("a", 90.0, [20.0, 45.0, 70.0])]
    plan = build_plan(analyses, PlanConfig(mode="clips"))

    assert [g.name for g in plan.groups] == ["a_01"]
    assert sum(s.kind == "hit" for s in plan.groups[0].segments) == 3
    assert 8.0 <= plan.groups[0].out_duration <= 20.0


def test_four_events_split_into_balanced_pairs():
    # 2+2, not 3+1: a lone trailing one-event clip reads as a leftover
    analyses = [make_analysis("a", 200.0, [20.0, 60.0, 100.0, 140.0])]
    plan = build_plan(analyses, PlanConfig(mode="clips"))

    hits = [sum(s.kind == "hit" for s in g.segments) for g in plan.groups]
    assert hits == [2, 2]


def test_clips_never_run_past_the_cap_even_snapped_to_a_slow_grid():
    # merged windows make the longest clips; the slow grid stretches cuts outward,
    # so the cap has to hold after snapping, not before
    analyses = [make_analysis("a", 240.0, [30.0, 36.0, 90.0, 96.0, 150.0])]
    beats = [round(i * 0.674, 3) for i in range(400)]  # 89 bpm
    plan = build_plan(analyses, PlanConfig(mode="clips"),
                      tracks=[Path("slow.mp3")], grids=[beats])

    assert plan.groups
    for group in plan.groups:
        assert group.out_duration <= 20.0 + 1e-3


def test_chained_highlights_keep_every_moment():
    # 10s apart: windows overlap (+-8/4) and chain-merged into a single window,
    # losing five moments of six; same-moment peaks (3s) still merge. Five
    # surviving windows then bundle 3+2 into two clips
    analyses = [make_analysis("a", 120.0, [20.0, 30.0, 40.0, 50.0, 60.0, 63.0])]
    plan = build_plan(analyses, PlanConfig(mode="clips"))

    assert [sum(s.kind == "hit" for s in g.segments) for g in plan.groups] == [3, 2]
    starts = [s.start for g in plan.groups for s in g.segments]
    assert starts == sorted(starts)


def test_clips_are_split_per_match_and_chronological():
    analyses = [make_analysis("МАТЧ 1", 200.0, [60.0, 30.0, 90.0, 120.0, 150.0]),
                make_analysis("b", 90.0, [40.0])]
    plan = build_plan(analyses, PlanConfig(mode="clips"))

    assert [g.name for g in plan.groups] == ["МАТЧ_1_01", "МАТЧ_1_02", "b_01"]
    for group in plan.groups:
        assert len({seg.src for seg in group.segments}) == 1  # a clip is one match
        starts = [s.start for s in group.segments]
        assert starts == sorted(starts)
    assert plan.groups[0].segments[-1].end <= plan.groups[1].segments[0].start


def test_a_sparse_grid_never_costs_a_highlight_its_hit():
    # period 4.0s: the snap window is half of that, wide enough that the trim
    # used to pop the last event's hit and leave a clip ending on a dangling lead
    analyses = [make_analysis("a", 240.0, [30.0, 36.0, 90.0, 96.0, 150.0])]
    beats = [round(i * 4.0, 3) for i in range(200)]
    plan = build_plan(analyses, PlanConfig(mode="clips"),
                      tracks=[Path("slow.mp3")], grids=[beats])

    assert [sum(s.kind == "hit" for s in g.segments) for g in plan.groups] == [3, 2]
    for group in plan.groups:
        assert group.segments[-1].kind != "lead"
        assert group.out_duration <= 20.0 + 1e-3


def test_snapping_never_rewinds_across_events_in_one_clip():
    # a stretched tail of one event used to cross into the next event's lead:
    # the rendered clip visibly jumped backwards between two moments
    analyses = [make_analysis(
        "a", 130.0, [31.08, 59.83, 60.77, 69.18, 110.94, 116.34, 116.41])]
    beats = [round(i * 0.5809, 3) for i in range(300)]  # 103.3 bpm
    plan = build_plan(analyses, PlanConfig(mode="clips"),
                      tracks=[Path("t.mp3")], grids=[beats])

    for group in plan.groups:
        for prev, seg in zip(group.segments, group.segments[1:]):
            if seg.kind == "lead" and seg.src == prev.src:
                assert seg.start >= prev.end - 1e-6


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
