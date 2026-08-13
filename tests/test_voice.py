"""voice.py's edge-tts path: fully offline -- the network call itself is monkeypatched
out, since a test suite that touches Microsoft's service is a test suite that fails
on a plane."""

from __future__ import annotations

import json
import subprocess

import pytest

from crcut import voice as vo


def _probe_audio(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", "stream=sample_rate,channels", "-of", "json", str(path)],
        capture_output=True, check=True,
    ).stdout
    return json.loads(out)["streams"][0]


def _fake_synth(calls):
    """Stands in for the network call: a 0.3s sine tone, encoded the way edge-tts
    would hand it back (mp3, at whatever path `_speak_edge` picked)."""

    def synth(text, voice, rate, pitch, out):
        calls.append((text, voice, rate, pitch))
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
             "-i", "sine=frequency=440:duration=0.3", str(out)],
            check=True, capture_output=True,
        )

    return synth


def test_speak_edge_caches_and_produces_44100_mono(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setattr(vo, "_edge_synth", _fake_synth(calls))

    path = vo.speak("Привет, мир.", "ru-RU-DmitryNeural", tmp_path, style="story")
    assert path.exists() and path.suffix == ".wav"
    stream = _probe_audio(path)
    assert stream["sample_rate"] == "44100"
    assert stream["channels"] == 1
    assert len(calls) == 1

    again = vo.speak("Привет, мир.", "ru-RU-DmitryNeural", tmp_path, style="story")
    assert again == path
    assert len(calls) == 1  # cache hit -- no second synth call


def test_speak_edge_failure_falls_back_to_say(monkeypatch, tmp_path, capsys):
    say_voice = vo._pick_say("ru")
    if not say_voice:
        pytest.skip("no say voice for ru on this machine")

    def raising_synth(text, voice, rate, pitch, out):
        raise RuntimeError("DNS failure")

    monkeypatch.setattr(vo, "_edge_synth", raising_synth)

    path = vo.speak("Привет, мир.", "ru-RU-DmitryNeural", tmp_path, style="story")
    assert path.exists()
    assert "edge-tts failed" in capsys.readouterr().err


def test_resolve_bare_name_and_pick_by_backend(monkeypatch):
    monkeypatch.setattr(vo, "_EDGE_OK", True)
    assert vo.resolve("Dmitry") == "ru-RU-DmitryNeural"
    assert vo.pick("ru") == vo.EDGE_VOICES["ru"][0]

    monkeypatch.setattr(vo, "_EDGE_OK", False)
    assert vo.pick("ru") == vo._pick_say("ru")


def test_story_style_is_the_default():
    assert "story" in vo.STYLES
    assert vo.DEFAULT_STYLE == "story"
