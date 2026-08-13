"""Single-pass ffmpeg rendering: one filter_complex per output file.

One pass means no intermediate files and no generation loss. The generated graph
is dumped to out/debug/ so it can be inspected when ffmpeg complains.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass
from pathlib import Path

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
FMT = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"


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
    sfx = _sfx_cues(group)
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

    # lanczos everywhere swscale runs -- that includes zoompan, which rescales every
    # punched-in frame and is otherwise the softest thing in the chain
    cmd = [FFMPEG, "-v", "error", "-stats", "-nostdin", "-y",
           "-sws_flags", "lanczos+accurate_rnd+full_chroma_int"]
    for src in inputs:
        cmd += ["-i", src]
    if music:
        cmd += ["-stream_loop", "-1", "-i", music]
    for st in stickers:
        cmd += ["-loop", "1", "-framerate", str(plan.fps), "-t", str(st.dur), "-i", str(st.path)]
    for path, _start in [*sfx, *voice]:
        cmd += ["-i", str(path)]

    cmd += ["-filter_complex", filtergraph, "-map", "[vout]"]
    cmd += ["-map", "[aout]", "-c:a", "aac", "-b:a", "256k", "-ar", "48000"] if has_audio \
        else ["-an"]
    cmd += [
        # crf 16 / medium: TikTok re-encodes whatever it gets, so the master has to
        # survive a second generation -- that is worth the extra minute per variant
        "-c:v", "libx264", "-crf", "16", "-preset", "medium",
        "-pix_fmt", "yuv420p", "-profile:v", "high", "-level", "4.2",
        "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
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
        # yuv444p all the way to the end: captions and stickers are overlaid after
        # this, and blending them into half-resolution chroma is what frays the
        # coloured edges of the text. The 4:2:0 conversion happens once, at [vout].
        # settb last, after zoompan -- xfade refuses inputs whose timebases disagree
        tail = f"{_punch(seg, plan)},format=yuv444p,settb=AVTB[v{i}]"
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


def _sfx_cues(group: Group) -> list[tuple[Path, float]]:
    """Whatever is in assets/sfx/, on every moment, cycling in name order.

    Nothing is synthesised: the moments coincide with the cuts, so a generated cue
    landed on every scene change and that is exactly what was unpleasant. An empty
    folder means no sound layer at all -- the zoom and the cross-fade carry the hit.
    """
    files = sorted(p for p in SFX_DIR.glob("*") if p.suffix.lower() in SFX_SUFFIXES)
    if not files:
        return []
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
    """Music, whatever is in assets/sfx/, and the narrator. True if there is an [aout].

    Everything is resampled to 48k stereo float on the way in: sidechaincompress
    refuses inputs whose formats disagree, and one conversion at the front is cleaner
    than several scattered through the graph.
    """
    labels: list[str] = []
    for i, (_path, start) in enumerate(sfx):
        graph.append(
            f"[{sfx_index + i}:a]{FMT},atrim=0:1.6,asetpts=PTS-STARTPTS,"
            f"adelay={int(start * 1000)}:all=1,volume=1.1[s{i}]"
        )
        labels.append(f"s{i}")

    for i, (_path, start) in enumerate(voice):
        graph.append(
            f"[{voice_index + i}:a]{FMT},asetpts=PTS-STARTPTS,"
            f"adelay={int(start * 1000)}:all=1,volume=1.7[n{i}]"
        )

    if voice:
        labels.append(_voice_bus(graph, len(voice), total, key=bool(music)))

    if music:
        fade_out = max(0.0, total - 0.8)
        graph.append(
            f"[{music_index}:a]{FMT},atrim=0:{total:.3f},asetpts=PTS-STARTPTS,"
            f"afade=t=in:st=0:d=0.25,afade=t=out:st={fade_out:.3f}:d=0.8,volume=0.9[bed]"
        )
        if voice:
            # ducking on the actual voice rather than a fixed -5 dB for the whole
            # video: the music stays at full level between lines and gets out of the
            # way only while he is talking
            graph.append(
                "[bed][key]sidechaincompress=threshold=0.03:ratio=8:"
                "attack=15:release=350:makeup=1:level_sc=2[duck]"
            )
            labels.append("duck")
        else:
            labels.append("bed")

    if not labels:
        return False

    mix = "".join(f"[{lbl}]" for lbl in labels)
    if len(labels) > 1:
        # longest, not first: the first bus is whichever layer exists, and an SFX cue
        # ends 1.6s after its hit -- with `first` it would cut the whole mix there
        mix += f"amix=inputs={len(labels)}:duration=longest:normalize=0,"
    graph.append(
        f"{mix}alimiter=limit=0.95,"
        # one loudness target for every variant, so a 28s cut and a 55s cut do not
        # arrive at different volumes; loudnorm outputs 192k, hence the resample after
        f"loudnorm=I=-14:TP=-1.5:LRA=11,"
        # soxr is not in every ffmpeg build; a wider swr kernel is available everywhere
        f"aresample=48000:filter_size=64:cutoff=0.97,"
        f"atrim=0:{total:.3f},apad,aformat=sample_rates=48000:channel_layouts=stereo[aout]"
    )
    return True


def _voice_bus(graph: list[str], cues: int, total: float, key: bool) -> str:
    """One narrator bus; with music it is split in two, the second copy keying the duck.

    Split rather than reused: a filtergraph label may only be consumed once -- and only
    when it is wanted, because an unconnected asplit output is a hard ffmpeg error.
    """
    heads = "".join(f"[n{i}]" for i in range(cues))
    summed = f"{heads}amix=inputs={cues}:duration=longest:normalize=0," if cues > 1 else heads
    tail = ",asplit=2[vox][key]" if key else "[vox]"
    graph.append(f"{summed}apad,atrim=0:{total:.3f},asetpts=PTS-STARTPTS{tail}")
    return "vox"


def load_metas(paths: list[str]) -> dict[str, Meta]:
    metas: dict[str, Meta] = {}
    for p in paths:
        try:
            metas[p] = probe(Path(p))
        except MediaError:
            continue
    return metas
