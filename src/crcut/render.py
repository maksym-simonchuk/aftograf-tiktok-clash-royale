"""Single-pass ffmpeg rendering: one filter_complex per output file.

One pass means no intermediate files and no generation loss. The generated graph
is dumped to out/debug/ so it can be inspected when ffmpeg complains.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

from . import sfx as sx
from . import voice as vo
from .media import FFMPEG, MediaError, Meta, probe
from .overlay import find_font, render_caption
from .plan import EditPlan, Group, Segment

ASPECT_TOLERANCE = 0.01
CAPTION_LEN = 1.7
MEME_LEN = 1.2
BAR_COLOR = "0xF7D046"
FONT_DIR = Path("assets/fonts")
MEME_DIR = Path("assets/memes")
SFX_DIR = Path("assets/sfx")
SFX_SUFFIXES = (".wav", ".mp3", ".m4a", ".aac", ".ogg")


@dataclass(frozen=True)
class Sticker:
    """An RGBA PNG overlaid for a moment -- a caption or a meme, same machinery."""

    path: Path
    start: float
    dur: float
    y: str  # overlay y expression, free to move over t
    width: int | None = None


def render_group(
    plan: EditPlan,
    group: Group,
    out_path: Path,
    *,
    debug_dir: Path | None = None,
    metas: dict[str, Meta] | None = None,
) -> Path:
    if not group.segments:
        raise ValueError(f"group {group.name} has no segments")

    used = sorted({s.src for s in group.segments})
    remap = {src: i for i, src in enumerate(used)}
    inputs = [plan.sources[src] for src in used]
    metas = metas or {}

    total = round(group.out_duration, 3)
    music = group.music or plan.music  # a variant may carry its own track
    cache_dir = out_path.parent / ".cache"
    stickers = _stickers(plan, group, cache_dir)
    sfx = _sfx_cues(group, cache_dir)
    voice = _voice_cues(group, plan.voice, plan.voice_style, cache_dir)
    sticker_index = len(inputs) + (1 if music else 0)

    graph, labels = _video_graph(plan, group, remap, inputs, metas)
    last = _join(graph, group, labels)
    last = _overlay_stickers(graph, last, stickers, sticker_index)
    # retention bar: a full-width strip slid in from the left, because drawbox's
    # `t` is its thickness, not the timestamp -- only overlay can read the clock
    bar_h = max(6, plan.height // 200)
    graph.append(f"color=c={BAR_COLOR}:s={plan.width}x{bar_h}:d={total}:r={plan.fps}[bar]")
    graph.append(
        f"[{last}][bar]overlay=x='-{plan.width}+{plan.width}*t/{total}':y=0:shortest=0,"
        f"format=yuv420p[vout]"
    )
    sfx_index = sticker_index + len(stickers)
    has_audio = _audio_graph(
        graph, music, total, len(inputs), sfx, sfx_index, voice, sfx_index + len(sfx)
    )

    filtergraph = ";".join(graph)
    if debug_dir:
        debug_dir.mkdir(parents=True, exist_ok=True)
        (debug_dir / f"filtergraph_{group.name}.txt").write_text(filtergraph.replace(";", ";\n"))

    cmd = [FFMPEG, "-v", "error", "-stats", "-nostdin", "-y"]
    for src in inputs:
        cmd += ["-i", src]
    if music:
        cmd += ["-stream_loop", "-1", "-i", music]
    for st in stickers:
        cmd += ["-loop", "1", "-framerate", str(plan.fps), "-t", str(st.dur), "-i", str(st.path)]
    for path, _start in [*sfx, *voice]:
        cmd += ["-i", str(path)]

    cmd += ["-filter_complex", filtergraph, "-map", "[vout]"]
    cmd += ["-map", "[aout]", "-c:a", "aac", "-b:a", "192k"] if has_audio else ["-an"]
    cmd += [
        "-c:v", "libx264", "-crf", "18", "-preset", "veryfast",
        "-pix_fmt", "yuv420p", "-profile:v", "high",
        "-r", str(plan.fps), "-t", str(total),
        "-movflags", "+faststart", str(out_path),
    ]

    out_path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        tail = proc.stderr.decode("utf-8", "replace").strip().splitlines()[-12:]
        raise MediaError(f"ffmpeg render failed for {group.name}:\n" + "\n".join(tail))
    return out_path


def _video_graph(
    plan: EditPlan,
    group: Group,
    remap: dict[int, int],
    inputs: list[str],
    metas: dict[str, Meta],
) -> tuple[list[str], list[str]]:
    w, h, fps = plan.width, plan.height, plan.fps
    target_aspect = w / h

    graph: list[str] = []
    labels: list[str] = []
    for i, seg in enumerate(group.segments):
        idx = remap[seg.src]
        src_path = inputs[idx]
        meta = metas.get(src_path)
        pillarbox = meta is None or abs(meta.aspect - target_aspect) > ASPECT_TOLERANCE

        base = (
            f"[{idx}:v]trim=start={seg.start:.3f}:end={seg.end:.3f},"
            f"setpts=(PTS-STARTPTS)/{seg.speed:.3f},fps={fps}"
        )
        # settb last, after zoompan -- xfade refuses inputs whose timebases disagree
        tail = f"{_punch(seg, plan)},format=yuv420p,settb=AVTB[v{i}]"
        if pillarbox:
            graph.append(base + f",split=2[f{i}s][b{i}s]")
            graph.append(
                f"[f{i}s]scale={w}:{h}:force_original_aspect_ratio=decrease,setsar=1[f{i}]"
            )
            graph.append(
                f"[b{i}s]scale={w}:{h}:force_original_aspect_ratio=increase,"
                f"crop={w}:{h},gblur=sigma=24,eq=brightness=-0.12,setsar=1[b{i}]"
            )
            graph.append(f"[b{i}][f{i}]overlay=(W-w)/2:(H-h)/2" + tail)
        else:
            graph.append(base + f",scale={w}:{h},setsar=1" + tail)
        labels.append(f"v{i}")

    return graph, labels


def _punch(seg: Segment, plan: EditPlan) -> str:
    """Impact zoom plus a short camera shake -- only on the moment itself.

    zoompan rather than crop: crop evaluates its output size once, so it cannot
    zoom over time. The zoom decays slower than the shake, so the crop always has
    margin left to shake inside.
    """
    if seg.kind not in ("hit", "hook"):
        return ""

    amount, decay = (0.10, 0.30) if seg.kind == "hit" else (0.13, 0.45)
    t = f"(on/{plan.fps})"
    zoom = f"1+{amount}*exp(-{t}/{decay})"
    shake = f"*exp(-{t}/0.20)"
    return (
        f",zoompan=z='{zoom}'"
        f":x='iw/2-(iw/zoom/2)+7*sin({t}*106){shake}'"
        f":y='ih/2-(ih/zoom/2)+6*cos({t}*82){shake}'"
        f":d=1:s={plan.width}x{plan.height}:fps={plan.fps}"
    )


def _join(graph: list[str], group: Group, labels: list[str]) -> str:
    """Cross-fade where the plan asked for one, hard cut everywhere else."""
    last = labels[0]
    acc = group.segments[0].out_duration
    for i, seg in enumerate(group.segments[1:], start=1):
        # a fade eats `trans_in` seconds off both shots; the plan sized it, re-clamp
        # anyway because beat snapping runs after the transitions are assigned
        dur = min(seg.trans_in, acc / 3.0, seg.out_duration / 3.0)
        if dur >= 0.12:
            offset = acc - dur
            graph.append(
                f"[{last}][{labels[i]}]xfade=transition={seg.trans_kind}:"
                f"duration={dur:.3f}:offset={offset:.3f},settb=AVTB[x{i}]"
            )
            acc = offset + seg.out_duration
        else:
            # concat hands back the input timebase; xfade rejects mismatched ones
            graph.append(f"[{last}][{labels[i]}]concat=n=2:v=1:a=0,settb=AVTB[x{i}]")
            acc += seg.out_duration
        last = f"x{i}"
    return last


def _stickers(plan: EditPlan, group: Group, cache_dir: Path) -> list[Sticker]:
    font = find_font(FONT_DIR)
    out: list[Sticker] = []
    for seg, raw_start in group.timeline():
        start = max(raw_start, 0.0)
        if seg.caption:
            # settles onto its line instead of appearing flat on it
            out.append(Sticker(
                render_caption(seg.caption, plan.width, cache_dir, font),
                start, CAPTION_LEN, f"H*0.60+40*exp(-9*(t-{start:.3f}))",
            ))

    memes = sorted(MEME_DIR.glob("*.png"))
    if memes:
        hits = [max(s, 0.0) for seg, s in group.timeline() if seg.kind == "hit"]
        for i, hit in enumerate(hits):
            start = hit + 0.25
            out.append(Sticker(
                memes[i % len(memes)], start, MEME_LEN,
                f"H*0.17-40*exp(-9*(t-{start:.3f}))", int(plan.width * 0.42),
            ))
    return out


def _overlay_stickers(graph: list[str], last: str, stickers: list[Sticker], first_index: int) -> str:
    for i, st in enumerate(stickers):
        scale = f"scale={st.width}:-1," if st.width else ""
        graph.append(
            f"[{first_index + i}:v]{scale}format=rgba,fade=t=in:st=0:d=0.15:alpha=1,"
            f"fade=t=out:st={st.dur - 0.25:.3f}:d=0.25:alpha=1,"
            f"setpts=PTS-STARTPTS+{st.start:.3f}/TB[c{i}]"
        )
        graph.append(
            f"[{last}][c{i}]overlay=x=(W-w)/2:y='{st.y}'"
            f":enable='between(t,{st.start:.3f},{st.start + st.dur:.3f})'[o{i}]"
        )
        last = f"o{i}"
    return last


def _sfx_cues(group: Group, cache_dir: Path) -> list[tuple[Path, float]]:
    """An impact on every moment. Cuts get nothing -- the cross-fade is enough.

    Files in assets/sfx/ replace the impact, cycling in name order.
    """
    files = sorted(p for p in SFX_DIR.glob("*") if p.suffix.lower() in SFX_SUFFIXES)
    files = files or [sx.impact(cache_dir)]
    hits = [start for seg, start in group.timeline() if seg.kind in ("hit", "hook")]
    return [(files[i % len(files)], max(start, 0.0)) for i, start in enumerate(hits)]


def _voice_cues(
    group: Group, voice: str | None, style: str, cache_dir: Path
) -> list[tuple[Path, float]]:
    """The captions marked for narration, plus the reactions between them.

    Not every caption is read: the plan decides which, so the old man comments on
    the video instead of dictating it.
    """
    if not voice or not vo.available():
        return []
    cues = []
    for seg, start in group.timeline():
        if seg.caption and seg.narrate:
            cues.append((vo.speak(seg.caption, voice, cache_dir, style), max(start, 0.0)))
        if seg.adlib:
            # a beat into the shot, so the reaction follows the moment it reacts to
            cues.append((vo.speak(seg.adlib, voice, cache_dir, style), max(start + 0.25, 0.0)))
    return cues


def _audio_graph(
    graph: list[str],
    music: str | None,
    total: float,
    music_index: int,
    sfx: list[tuple[Path, float]],
    sfx_index: int,
    voice: list[tuple[Path, float]],
    voice_index: int,
) -> bool:
    """Music bed, impacts and the narrator. Returns whether there is an [aout] to map."""
    labels: list[str] = []
    if music:
        fade_out = max(0.0, total - 0.8)
        # the bed steps back when someone is talking over it
        level = 0.55 if voice else 0.9
        graph.append(
            f"[{music_index}:a]atrim=0:{total:.3f},asetpts=PTS-STARTPTS,"
            f"afade=t=in:st=0:d=0.25,afade=t=out:st={fade_out:.3f}:d=0.8,volume={level}[bed]"
        )
        labels.append("bed")

    for i, (_path, start) in enumerate(sfx):
        ms = int(start * 1000)
        graph.append(
            f"[{sfx_index + i}:a]atrim=0:1.6,asetpts=PTS-STARTPTS,"
            f"adelay={ms}:all=1,volume=1.1[s{i}]"
        )
        labels.append(f"s{i}")

    for i, (_path, start) in enumerate(voice):
        ms = int(start * 1000)
        graph.append(
            f"[{voice_index + i}:a]asetpts=PTS-STARTPTS,adelay={ms}:all=1,volume=1.7[n{i}]"
        )
        labels.append(f"n{i}")

    if not labels:
        return False

    mix = "".join(f"[{lbl}]" for lbl in labels)
    if len(labels) > 1:
        mix += f"amix=inputs={len(labels)}:duration=first:normalize=0,alimiter=limit=0.95,"
    graph.append(
        f"{mix}atrim=0:{total:.3f},apad,aformat=sample_rates=48000:channel_layouts=stereo[aout]"
    )
    return True


def load_metas(paths: list[str]) -> dict[str, Meta]:
    metas: dict[str, Meta] = {}
    for p in paths:
        try:
            metas[p] = probe(Path(p))
        except MediaError:
            continue
    return metas
