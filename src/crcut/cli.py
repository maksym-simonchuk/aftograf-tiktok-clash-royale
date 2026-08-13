"""crcut CLI: folder of Clash Royale matches -> TikTok-ready video(s)."""

from __future__ import annotations

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

from . import voice as vo
from .detect import Analysis, DetectConfig, analyze
from .media import MediaError, Meta, cache_path, find_videos, probe
from .music import BEDS, BPM, beat_grid, ensure_bed
from .plan import VARIANT_SCALE, EditPlan, PlanConfig, build_plan, detect_beats
from .render import load_metas, render_group

MUSIC_EXT = {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"}


def main(argv: list[str] | None = None) -> int:
    args = _parse(argv or sys.argv[1:])
    if args.voices:
        for name, locale in vo.voices():
            print(f"{locale}  {name}")
        return 0

    root = Path.cwd()
    out_dir = Path(args.out)
    debug_dir = out_dir / "debug" if args.debug else None

    try:
        plan = _load_or_build_plan(args, root, out_dir, debug_dir)
    except (MediaError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if args.analyze_only:
        _print_summary(plan)
        return 0

    metas = load_metas(plan.sources)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for group in plan.groups:
        target = _output_path(out_dir, plan, group, stamp)
        print(f"rendering {group.name} -> {target}  ({group.out_duration:.1f}s)")
        try:
            render_group(plan, group, target, debug_dir=debug_dir, metas=metas)
        except MediaError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        target.with_suffix(".txt").write_text(
            group.title + "\n\n" + " ".join(group.hashtags) + "\n", encoding="utf-8"
        )

    print(f"done -> {out_dir}")
    return 0


def _load_or_build_plan(args, root: Path, out_dir: Path, debug_dir: Path | None) -> EditPlan:
    if args.from_plan:
        return EditPlan.load(Path(args.from_plan))

    folder = Path(args.folder).expanduser().resolve()
    if not folder.exists():
        raise ValueError(f"{folder} does not exist")

    videos = find_videos(folder)
    if not videos:
        raise ValueError(f"no video files in {folder}")

    det_cfg = DetectConfig()
    metas = [probe(v) for v in videos]
    print(f"analyzing {len(metas)} file(s)...")

    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=min(4, len(metas))) as pool:
        analyses = list(pool.map(lambda m: _analyze_cached(m, det_cfg, root, args.no_cache), metas))
    print(f"analysis done in {time.monotonic() - started:.1f}s")

    for an in analyses:
        print(
            f"  {Path(an.meta.path).name}: {len(an.highlights)} highlight(s), "
            f"match {an.action_start:.1f}-{an.action_end:.1f}s"
        )
        if debug_dir:
            _write_debug(an, debug_dir)

    tracks, beats = _resolve_music(args, root, args.duration)
    if tracks:
        names = ", ".join(t.name for t in tracks[:3])
        print(f"music: {names} ({len(beats)} beats)" if beats else f"music: {names}")

    voice = _resolve_voice(args)
    if voice:
        print(f"voice: {voice} ({args.voice_style})")

    cfg = PlanConfig(mode=args.mode, lang=args.lang, target_duration=args.duration,
                     variants=args.variants, voice=voice, voice_style=args.voice_style)
    plan = build_plan(analyses, cfg, music=tracks[0] if tracks else None, beats=beats)
    if len(tracks) > 1:  # a different track per variant when there is a choice
        for i, group in enumerate(plan.groups):
            group.music = str(tracks[i % len(tracks)])
    plan.dump(out_dir / "plan.json")
    print(f"plan -> {out_dir / 'plan.json'}")
    return plan


# ---------------------------------------------------------------- analysis cache


def _analyze_cached(meta: Meta, cfg: DetectConfig, root: Path, no_cache: bool) -> Analysis:
    path = cache_path(root, Path(meta.path), ".npz")
    if not no_cache and path.exists():
        cached = _cache_load(path, meta)
        if cached is not None:
            return cached

    an = analyze(meta, cfg)
    np.savez_compressed(
        path,
        t=an.t,
        motion=an.motion,
        flash=an.flash,
        shake=an.shake,
        hype=an.hype,
        meta=json.dumps(
            {
                "highlights": an.highlights,
                "action_start": an.action_start,
                "action_end": an.action_end,
            }
        ),
    )
    return an


def _cache_load(path: Path, meta: Meta) -> Analysis | None:
    try:
        data = np.load(path, allow_pickle=False)
        extra = json.loads(data["meta"].item())
        return Analysis(
            meta=meta,
            t=data["t"],
            motion=data["motion"],
            flash=data["flash"],
            shake=data["shake"],
            hype=data["hype"],
            highlights=list(extra["highlights"]),
            action_start=float(extra["action_start"]),
            action_end=float(extra["action_end"]),
        )
    except Exception:
        return None


# ---------------------------------------------------------------- debug


def _write_debug(an: Analysis, debug_dir: Path) -> None:
    debug_dir.mkdir(parents=True, exist_ok=True)
    rows = ["t,motion,flash,shake,hype"]
    rows += [
        f"{t:.2f},{m:.4f},{f:.5f},{s:.4f},{h:.4f}"
        for t, m, f, s, h in zip(an.t, an.motion, an.flash, an.shake, an.hype)
    ]
    (debug_dir / f"signals_{Path(an.meta.path).stem}.csv").write_text("\n".join(rows))


def _print_summary(plan: EditPlan) -> None:
    for group in plan.groups:
        print(f"\n[{group.name}] {group.out_duration:.1f}s  \"{group.title}\"")
        for seg in group.segments:
            print(
                f"  {seg.kind:<5} src={seg.src} {seg.start:7.2f}-{seg.end:7.2f} "
                f"x{seg.speed:.2f} -> {seg.out_duration:5.2f}s  score={seg.score:.2f}"
            )


# ---------------------------------------------------------------- helpers


def _resolve_music(args, root: Path, duration: float) -> tuple[list[Path], list[float]]:
    """Tracks to rotate through, plus the beat grid of the first one."""
    if args.no_music:
        return [], []
    if args.music:
        path = Path(args.music).expanduser()
        if not path.exists():
            raise ValueError(f"music file not found: {path}")
        return [path], detect_beats(path)

    folder = root / "assets" / "music"
    tracks = sorted(p for p in folder.iterdir() if p.suffix.lower() in MUSIC_EXT) \
        if folder.is_dir() else []
    if tracks:
        return tracks, detect_beats(tracks[0])

    # nothing dropped in: play the synthesised beds, whose beats are exact by
    # construction. Long enough for the longest variant, so they never have to loop,
    # and one per variant so three files in a row do not sound like one.
    longest = duration * max(VARIANT_SCALE)
    wanted = min(len(BEDS), max(args.variants, 1))
    beds = [ensure_bed(root / ".crcut" / f"bed_{BEDS[i].name}_{int(BPM)}bpm.wav", longest, i)
            for i in range(wanted)]
    return beds, beat_grid(longest)


def _resolve_voice(args) -> str | None:
    """The system voice that reads the captions; None means a silent narrator."""
    if args.no_voice:
        return None
    if not vo.available():
        print("voice: `say` not found, rendering without narration", file=sys.stderr)
        return None
    if args.voice:
        found = vo.resolve(args.voice, args.lang)
        if not found:
            raise ValueError(f"voice not installed: {args.voice} (see --voices)")
        return found
    return vo.pick(args.lang)


def _output_path(out_dir: Path, plan: EditPlan, group, stamp: str) -> Path:
    if plan.mode == "clips":
        return out_dir / "clips" / f"{group.name}.mp4"
    return out_dir / f"{group.name}_{stamp}.mp4"


def _parse(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="crcut", description="Clash Royale -> TikTok auto-editor")
    p.add_argument("folder", nargs="?", default="inbox", help="folder with match recordings")
    p.add_argument("--clips", dest="mode", action="store_const", const="clips", default="montage",
                   help="render one file per highlight instead of a single montage")
    p.add_argument("--montage", dest="mode", action="store_const", const="montage")
    p.add_argument("--duration", type=float, default=42.0, help="target montage duration, seconds")
    p.add_argument("--variants", type=int, default=3,
                   help="how many montage cuts to render (different hook, length and copy)")
    p.add_argument("--lang", choices=["ru", "en"], default="ru", help="language of titles/captions")
    p.add_argument("--music", help="music track (default: first file in assets/music/)")
    p.add_argument("--no-music", action="store_true", help="render silent (add sound in the TikTok app)")
    p.add_argument("--voice", help="system voice that reads the captions (see --voices)")
    p.add_argument("--voice-style", choices=sorted(vo.STYLES), default=vo.DEFAULT_STYLE,
                   help="how that voice is shaped (see --help choices)")
    p.add_argument("--no-voice", action="store_true", help="no narration over the captions")
    p.add_argument("--voices", action="store_true", help="list installed system voices and exit")
    p.add_argument("--out", default="out", help="output folder")
    p.add_argument("--analyze-only", action="store_true", help="write out/plan.json and stop")
    p.add_argument("--from-plan", help="render an existing (possibly hand-edited) plan.json")
    p.add_argument("--debug", action="store_true", help="write signal CSVs and filtergraphs")
    p.add_argument("--no-cache", action="store_true", help="ignore cached analysis")
    return p.parse_args(argv)


if __name__ == "__main__":
    raise SystemExit(main())
