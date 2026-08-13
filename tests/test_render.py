from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest
from PIL import Image

from crcut import render
from crcut import voice as vo
from crcut.detect import analyze
from crcut.media import probe
from crcut.plan import EditPlan, PlanConfig, build_plan
from crcut.render import load_metas, render_group


def ffprobe_json(path: Path, stream: str = "v:0") -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", stream,
         "-show_entries", "stream=width,height,codec_name,pix_fmt",
         "-show_entries", "format=duration", "-of", "json", str(path)],
        capture_output=True, check=True,
    ).stdout
    return json.loads(out)


def test_end_to_end_montage_render(fake_cr, tmp_path):
    video, _ = fake_cr
    analyses = [analyze(probe(video))]
    plan = build_plan(analyses, PlanConfig(target_duration=12.0))

    out = render_group(plan, plan.groups[0], tmp_path / "montage.mp4",
                       debug_dir=tmp_path / "debug", metas=load_metas(plan.sources))

    assert out.exists()
    info = ffprobe_json(out)
    stream = info["streams"][0]
    assert (stream["width"], stream["height"]) == (1080, 1920)
    assert stream["codec_name"] == "h264"
    assert stream["pix_fmt"] == "yuv420p"
    assert abs(float(info["format"]["duration"]) - plan.groups[0].out_duration) < 1.0
    assert (tmp_path / "debug" / f"filtergraph_{plan.groups[0].name}.txt").exists()


def test_captions_and_transitions_reach_the_filtergraph(fake_cr, tmp_path):
    video, _ = fake_cr
    plan = build_plan([analyze(probe(video))], PlanConfig(target_duration=12.0))
    render_group(plan, plan.groups[0], tmp_path / "montage.mp4",
                 debug_dir=tmp_path / "debug", metas=load_metas(plan.sources))

    graph = (tmp_path / "debug" / f"filtergraph_{plan.groups[0].name}.txt").read_text()
    assert "xfade=transition=" in graph
    assert graph.count("overlay=x=(W-w)/2") == sum(bool(s.caption) for s in plan.groups[0].segments)
    assert "zoompan" in graph


def test_memes_are_overlaid_when_the_folder_has_any(fake_cr, tmp_path, monkeypatch):
    video, _ = fake_cr
    memes = tmp_path / "memes"
    memes.mkdir()
    Image.new("RGBA", (200, 200), (255, 0, 0, 200)).save(memes / "pepe.png")
    monkeypatch.setattr(render, "MEME_DIR", memes)

    plan = build_plan([analyze(probe(video))], PlanConfig(target_duration=12.0))
    render_group(plan, plan.groups[0], tmp_path / "memes.mp4",
                 debug_dir=tmp_path / "debug", metas=load_metas(plan.sources))

    graph = (tmp_path / "debug" / f"filtergraph_{plan.groups[0].name}.txt").read_text()
    hits = sum(s.kind == "hit" for s in plan.groups[0].segments)
    assert hits > 0
    assert graph.count("scale=453:-1") == hits


def test_sfx_are_mixed_in_when_the_folder_has_any(fake_cr, tmp_path, monkeypatch):
    video, _ = fake_cr
    sfx_dir = tmp_path / "sfx"
    sfx_dir.mkdir()
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=220:duration=0.4",
         str(sfx_dir / "hit.wav")], check=True,
    )
    monkeypatch.setattr(render, "SFX_DIR", sfx_dir)

    plan = build_plan([analyze(probe(video))], PlanConfig(target_duration=12.0))
    out = render_group(plan, plan.groups[0], tmp_path / "sfx.mp4",
                       metas=load_metas(plan.sources))

    assert ffprobe_json(out, "a:0")["streams"][0]["codec_name"] == "aac"


def test_impacts_and_whooshes_are_synthesised_when_the_folder_is_empty(
    fake_cr, tmp_path, monkeypatch
):
    monkeypatch.setattr(render, "SFX_DIR", tmp_path / "nothing-here")

    video, _ = fake_cr
    plan = build_plan([analyze(probe(video))], PlanConfig(target_duration=12.0))
    render_group(plan, plan.groups[0], tmp_path / "sfx.mp4",
                 debug_dir=tmp_path / "debug", metas=load_metas(plan.sources))

    graph = (tmp_path / "debug" / f"filtergraph_{plan.groups[0].name}.txt").read_text()
    segments = plan.groups[0].segments
    hits = sum(s.kind in ("hit", "hook") for s in segments)
    cuts = sum(s.trans_in > 0 for s in segments)
    assert hits and cuts
    assert graph.count("atrim=0:1.6") == hits + cuts


def test_every_caption_gets_a_narration_line(fake_cr, tmp_path):
    if not vo.available() or not vo.pick("ru"):
        pytest.skip("no system TTS")

    video, _ = fake_cr
    cfg = PlanConfig(target_duration=12.0, voice=vo.pick("ru"))
    plan = build_plan([analyze(probe(video))], cfg)
    out = render_group(plan, plan.groups[0], tmp_path / "voice.mp4",
                       debug_dir=tmp_path / "debug", metas=load_metas(plan.sources))

    graph = (tmp_path / "debug" / f"filtergraph_{plan.groups[0].name}.txt").read_text()
    segments = plan.groups[0].segments
    spoken = sum(bool(s.caption) for s in segments) + sum(bool(s.adlib) for s in segments)
    assert graph.count("volume=1.7") == spoken
    assert ffprobe_json(out, "a:0")["streams"][0]["codec_name"] == "aac"


def test_plan_roundtrip_through_disk(fake_cr, tmp_path):
    video, _ = fake_cr
    plan = build_plan([analyze(probe(video))], PlanConfig(target_duration=12.0))
    path = tmp_path / "plan.json"
    plan.dump(path)

    assert EditPlan.load(path).to_dict() == plan.to_dict()


def test_hand_edited_plan_changes_the_output(fake_cr, tmp_path):
    video, _ = fake_cr
    plan = build_plan([analyze(probe(video))], PlanConfig(target_duration=12.0))
    path = tmp_path / "plan.json"
    plan.dump(path)

    data = json.loads(path.read_text())
    data["groups"][0]["segments"] = data["groups"][0]["segments"][:1]
    path.write_text(json.dumps(data))

    edited = EditPlan.load(path)
    out = render_group(edited, edited.groups[0], tmp_path / "edited.mp4",
                       metas=load_metas(edited.sources))
    assert abs(float(ffprobe_json(out)["format"]["duration"]) - edited.groups[0].out_duration) < 0.5
