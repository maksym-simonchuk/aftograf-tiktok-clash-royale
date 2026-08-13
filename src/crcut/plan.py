"""Highlight scoring, montage assembly, beat snapping -- produces the EditPlan JSON.

The EditPlan is the seam between analysis and rendering: `--analyze-only` writes
it, `--from-plan` renders it, and you can hand-edit it in between.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .detect import Analysis

PLAN_VERSION = 1


@dataclass(frozen=True)
class PlanConfig:
    mode: str = "montage"
    lang: str = "ru"
    target_duration: float = 42.0
    width: int = 1080
    height: int = 1920
    fps: int = 30
    # window around a detected event
    pre: float = 4.5
    post: float = 2.0
    clip_pre: float = 8.0
    clip_post: float = 4.0
    # speed ramps
    lead_speed: float = 1.35
    hit_speed: float = 0.55
    hit_pre: float = 1.2
    hit_post: float = 0.5
    max_lead: float = 3.5  # merged windows must not become one long unedited shot
    hook_len: float = 0.8
    hook_speed: float = 0.7
    min_segment: float = 0.35
    beat_snap: float = 0.30
    # cross-fade between shots (never inside one, where a fade would read as a stutter)
    transition: float = 0.30
    caption_len: float = 1.7
    variants: int = 3
    voice: str | None = None  # system voice that reads the captions out loud
    voice_style: str = "grandpa"  # recipe in voice.STYLES: how that voice is shaped


@dataclass
class Segment:
    src: int
    start: float
    end: float
    speed: float
    kind: str
    score: float = 0.0
    trans_in: float = 0.0  # cross-fade overlap with the previous shot, 0 = hard cut
    trans_kind: str = ""
    caption: str = ""
    narrate: bool = False  # is that caption also read out loud, or only drawn
    adlib: str = ""  # spoken only -- the narrator's reaction, never drawn on screen

    @property
    def out_duration(self) -> float:
        return (self.end - self.start) / self.speed


@dataclass
class Group:
    name: str
    title: str
    hashtags: list[str]
    segments: list[Segment]
    music: str | None = None  # overrides the plan-wide track, so variants can differ

    @property
    def out_duration(self) -> float:
        """Cross-fades overlap, so every transition shortens the result."""
        return sum(s.out_duration - s.trans_in for s in self.segments)

    def timeline(self) -> list[tuple[Segment, float]]:
        """Each segment with the output timestamp it starts at."""
        out: list[tuple[Segment, float]] = []
        t = 0.0
        for seg in self.segments:
            t -= seg.trans_in
            out.append((seg, t))
            t += seg.out_duration
        return out


@dataclass
class EditPlan:
    version: int
    mode: str
    lang: str
    width: int
    height: int
    fps: int
    music: str | None
    voice: str | None
    voice_style: str
    sources: list[str]
    groups: list[Group]
    events: dict[str, list[float]] = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "mode": self.mode,
            "lang": self.lang,
            "width": self.width,
            "height": self.height,
            "fps": self.fps,
            "music": self.music,
            "voice": self.voice,
            "voice_style": self.voice_style,
            "sources": self.sources,
            "events": {k: [round(x, 3) for x in v] for k, v in self.events.items()},
            "groups": [
                {
                    "name": g.name,
                    "title": g.title,
                    "hashtags": g.hashtags,
                    "music": g.music,
                    "segments": [
                        {
                            "src": s.src,
                            "start": round(s.start, 3),
                            "end": round(s.end, 3),
                            "speed": round(s.speed, 3),
                            "kind": s.kind,
                            "score": round(s.score, 3),
                            "trans_in": round(s.trans_in, 3),
                            "trans_kind": s.trans_kind,
                            "caption": s.caption,
                            "narrate": s.narrate,
                            "adlib": s.adlib,
                        }
                        for s in g.segments
                    ],
                }
                for g in self.groups
            ],
        }

    def dump(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.to_dict(), ensure_ascii=False, indent=2, sort_keys=False))

    @staticmethod
    def load(path: Path) -> EditPlan:
        d = json.loads(Path(path).read_text())
        return EditPlan(
            version=d["version"],
            mode=d["mode"],
            lang=d["lang"],
            width=d["width"],
            height=d["height"],
            fps=d["fps"],
            music=d.get("music"),
            voice=d.get("voice"),
            voice_style=d.get("voice_style", "grandpa"),
            sources=d["sources"],
            events=d.get("events", {}),
            groups=[
                Group(
                    name=g["name"],
                    title=g["title"],
                    hashtags=g["hashtags"],
                    segments=[Segment(**s) for s in g["segments"]],
                    music=g.get("music"),
                )
                for g in d["groups"]
            ],
        )


@dataclass
class Window:
    src: int
    start: float
    end: float
    peak: float
    score: float


# ---------------------------------------------------------------- windows


def build_windows(analyses: list[Analysis], cfg: PlanConfig) -> list[Window]:
    pre = cfg.clip_pre if cfg.mode == "clips" else cfg.pre
    post = cfg.clip_post if cfg.mode == "clips" else cfg.post

    windows: list[Window] = []
    for src, an in enumerate(analyses):
        limit = min(an.meta.duration, an.action_end + 1.0)

        raw: list[Window] = []
        for peak in an.highlights:
            start, end = max(an.action_start, peak - pre), min(limit, peak + post)
            if end - start < 2.0:
                continue
            raw.append(Window(src=src, start=start, end=end, peak=peak, score=0.0))

        for w in _merge_windows(raw):
            w.score = _score(w, an, limit)
            windows.append(w)

    return windows


def _merge_windows(windows: list[Window]) -> list[Window]:
    out: list[Window] = []
    for w in sorted(windows, key=lambda x: x.start):
        if out and w.start <= out[-1].end:
            prev = out[-1]
            prev.end = max(prev.end, w.end)
            prev.peak = w.peak
        else:
            out.append(w)
    return out


def _score(w: Window, an: Analysis, limit: float) -> float:
    mask = (an.t >= w.start) & (an.t <= w.end)
    if not mask.any():
        return 0.0

    hype = np.clip(an.hype[mask], 0.0, None)
    score = float(hype.mean() + hype.max())
    if w.peak >= limit - 30.0:  # clutch / overtime finish
        score *= 1.5
    return score


# ---------------------------------------------------------------- segments


def segments_for(w: Window, cfg: PlanConfig) -> list[Segment]:
    lead_speed = cfg.lead_speed if cfg.mode == "montage" else 1.25
    hit_start = max(w.start, w.peak - cfg.hit_pre)
    hit_end = min(w.end, w.peak + cfg.hit_post)
    lead_start = max(w.start, hit_start - cfg.max_lead * lead_speed)

    out: list[Segment] = []
    if hit_start - lead_start >= cfg.min_segment:
        out.append(Segment(w.src, lead_start, hit_start, lead_speed, "lead", w.score))
    if hit_end - hit_start >= cfg.min_segment:
        out.append(Segment(w.src, hit_start, hit_end, cfg.hit_speed, "hit", w.score))
    if w.end - hit_end >= cfg.min_segment:
        out.append(Segment(w.src, hit_end, w.end, 1.0, "tail", w.score))
    return out


def build_plan(
    analyses: list[Analysis],
    cfg: PlanConfig,
    tracks: list[Path] | None = None,
    grids: list[list[float]] | None = None,
) -> EditPlan:
    """`tracks` rotate over the groups and each group snaps to its own grid in `grids`.

    A montage is three variants over three different songs, and a cut is only on the
    beat of the song it is actually playing over -- one shared grid would put two of
    the three variants off it.
    """
    tracks, grids = tracks or [], grids or []

    def music_of(i: int) -> str | None:
        return str(tracks[i % len(tracks)]) if tracks else None

    def grid_of(i: int) -> list[float] | None:
        return grids[i % len(grids)] if grids else None

    sources = [a.meta.path for a in analyses]
    windows = build_windows(analyses, cfg)
    if not windows:
        raise ValueError("no highlight windows found -- run with --debug and inspect out/debug/")

    ranked = sorted(windows, key=lambda w: w.score, reverse=True)
    seed = "|".join(Path(s).name for s in sources)

    groups: list[Group] = []
    cursor = 0  # walks the caption pool across groups, so no line is reused in one run
    ad_cursor = 0
    if cfg.mode == "clips":
        for i, w in enumerate(ranked):
            title = title_for(cfg.lang, seed + str(i))
            segments = _decorate(segments_for(w, cfg), title, cfg,
                                 caption_from=cursor, adlib_from=ad_cursor)
            cursor += _captions_used(segments)
            ad_cursor += _adlibs_used(segments)
            groups.append(
                Group(f"clip_{i:02d}", title, hashtags_for(cfg.lang),
                      _snapped(segments, grid_of(i), cfg), music_of(i))
            )
    else:
        # several ready-to-post cuts, not one: different cold open, length and
        # copy, so there is something to pick between without re-running anything
        for v in range(max(1, cfg.variants)):
            title = title_for(cfg.lang, f"{seed}#{v}")
            target = cfg.target_duration * VARIANT_SCALE[v % len(VARIANT_SCALE)]
            segments = _montage_segments(ranked, cfg, target, hook=v)
            segments = _decorate(segments, title, cfg, shift=v,
                                 caption_from=cursor, adlib_from=ad_cursor)
            segments = _trim_to_target(segments, target, cfg.min_segment)
            cursor += _captions_used(segments)
            ad_cursor += _adlibs_used(segments)
            groups.append(
                Group(f"montage_v{v + 1}", title, hashtags_for(cfg.lang),
                      _snapped(segments, grid_of(v), cfg), music_of(v))
            )

    return EditPlan(
        version=PLAN_VERSION,
        mode=cfg.mode,
        lang=cfg.lang,
        width=cfg.width,
        height=cfg.height,
        fps=cfg.fps,
        music=music_of(0),
        voice=cfg.voice,
        voice_style=cfg.voice_style,
        sources=sources,
        groups=groups,
        events={Path(a.meta.path).name: a.highlights for a in analyses},
    )


def _decorate(
    segments: list[Segment],
    title: str,
    cfg: PlanConfig,
    shift: int = 0,
    caption_from: int = 0,
    adlib_from: int = 0,
) -> list[Segment]:
    """Cross-fades, on-screen captions and the reactions only the narrator says."""
    segments = _assign_captions(_assign_transitions(segments, cfg, shift), title, cfg, caption_from)
    return _assign_adlibs(segments, cfg, adlib_from)


def _assign_transitions(segments: list[Segment], cfg: PlanConfig, shift: int = 0) -> list[Segment]:
    """Cross-fade only where the picture actually jumps.

    Inside one window lead/hit/tail are contiguous source frames, so a fade there
    would read as a stutter rather than a transition.
    """
    for i, seg in enumerate(segments):
        prev = segments[i - 1] if i else None
        if prev is None or (seg.src == prev.src and abs(seg.start - prev.end) < 0.05):
            continue
        # a fade longer than a third of either shot swallows the shot itself
        dur = min(cfg.transition, prev.out_duration / 3.0, seg.out_duration / 3.0)
        if dur < 0.12:
            continue
        seg.trans_in = round(dur, 3)
        seg.trans_kind = TRANSITIONS[(i + shift) % len(TRANSITIONS)]
    return segments


def _assign_captions(
    segments: list[Segment], title: str, cfg: PlanConfig, start: int = 0
) -> list[Segment]:
    """`start` is a running position in the pool, not a per-group restart: two cuts
    of the same match must not be captioned with the same lines."""
    pool = CAPTIONS.get(cfg.lang, CAPTIONS["ru"])
    shown = 0
    for i, seg in enumerate(segments):
        if i == 0:  # the hook in a montage, the opening shot in a clip
            seg.caption = plain_text(title)
            seg.narrate = True  # the opening line always gets read: it sets the voice up
        elif seg.kind == "hit":
            seg.caption = pool[(start + shown) % len(pool)]
            seg.narrate = shown % 2 == 0  # the rest are read every other time
            shown += 1
    return segments


def _assign_adlibs(segments: list[Segment], cfg: PlanConfig, start: int = 0) -> list[Segment]:
    """Spoken reactions that are never written on screen.

    They sit on the tail of a moment: the caption is read as the hit lands, the
    old man comments right after it, so the two never talk over each other.
    """
    pool = ADLIBS.get(cfg.lang, ADLIBS["ru"])
    used = 0
    for i, seg in enumerate(s for s in segments if s.kind == "tail"):
        if i % 3:  # every third tail -- more often than that and he never shuts up
            continue
        seg.adlib = pool[(start + used) % len(pool)]
        used += 1
    return segments


def _captions_used(segments: list[Segment]) -> int:
    return sum(1 for seg in segments[1:] if seg.kind == "hit")


def _adlibs_used(segments: list[Segment]) -> int:
    return sum(1 for seg in segments if seg.adlib)


def _montage_segments(
    ranked: list[Window], cfg: PlanConfig, target: float, hook: int = 0
) -> list[Segment]:
    chosen: list[Window] = []
    total = 0.0
    for w in ranked:
        chosen.append(w)
        total += sum(s.out_duration for s in segments_for(w, cfg))
        if total >= target:
            break

    best = ranked[hook % len(ranked)]
    hook_seg = Segment(
        src=best.src,
        start=max(0.0, best.peak - cfg.hook_len / 2),
        end=best.peak + cfg.hook_len / 2,
        speed=cfg.hook_speed,
        kind="hook",
        score=best.score,
    )

    body: list[Segment] = []
    for w in sorted(chosen, key=lambda x: (x.src, x.start)):
        body.extend(segments_for(w, cfg))

    return [hook_seg, *body]


def _out_total(segments: list[Segment]) -> float:
    return sum(s.out_duration - s.trans_in for s in segments)


def _trim_to_target(segments: list[Segment], target: float, min_segment: float) -> list[Segment]:
    # epsilon, not 0: a room of ~1e-17 leaves out_duration unchanged after the
    # subtraction and the loop never converges
    eps = 1e-3
    overshoot = _out_total(segments) - target
    while overshoot > 1.5 and len(segments) > 1:
        last = segments[-1]
        room = last.out_duration - min_segment
        if room <= eps:
            segments.pop()
        else:
            last.end -= min(room, overshoot) * last.speed
        overshoot = _out_total(segments) - target
    return segments


def _snapped(segments: list[Segment], beats: list[float] | None, cfg: PlanConfig) -> list[Segment]:
    if not beats:
        return segments

    arr = np.asarray(beats, dtype=np.float64)
    out_t = 0.0
    for seg in segments:
        out_t -= seg.trans_in
        desired = out_t + seg.out_duration
        nearest = float(arr[int(np.argmin(np.abs(arr - desired)))])
        new_len = nearest - out_t
        if abs(nearest - desired) <= cfg.beat_snap and new_len >= cfg.min_segment:
            delta = (new_len - seg.out_duration) * seg.speed
            if seg.kind == "tail":
                seg.end += delta
            else:
                seg.start -= delta
            if seg.start < 0:
                seg.start = 0.0
        out_t += seg.out_duration
    return segments


def detect_beats(music: Path | None) -> list[float]:
    if not music:
        return []
    try:
        import librosa
    except ImportError:
        return []
    y, sr = librosa.load(str(music), mono=True)
    _, frames = librosa.beat.beat_track(y=y, sr=sr)
    return [float(t) for t in librosa.frames_to_time(frames, sr=sr)]


# ---------------------------------------------------------------- copy

TITLES = {
    "ru": [
        "ТАКОГО КЛАТЧА ТЫ ЕЩЁ НЕ ВИДЕЛ 😳",
        "ОН РЕАЛЬНО ЭТОГО НЕ ЖДАЛ 🔥",
        "ЛАСТ ХИТ РЕШИЛ ВСЁ ⚡",
        "ДОСМОТРИ ДО КОНЦА 👀",
        "ДОП. ВРЕМЯ РЕШАЕТ 👑",
        "Я НЕ ВЕРИЛ ДО ПОСЛЕДНЕЙ СЕКУНДЫ 😭",
    ],
    "en": [
        "THIS CLUTCH IS INSANE 😳",
        "HE REALLY DIDN'T SEE IT COMING 🔥",
        "LAST HIT DECIDED EVERYTHING ⚡",
        "WATCH TILL THE END 👀",
        "OVERTIME DECIDES IT 👑",
        "I DIDN'T BELIEVE IT TILL THE LAST SECOND 😭",
    ],
}

# full cut / short one for the loop / long one for watch time
VARIANT_SCALE = [1.0, 0.62, 1.28]

# smooth ones only -- a hard wipe between two shots of the same arena reads as a glitch
TRANSITIONS = ["smoothleft", "dissolve", "circleopen", "smoothup", "smoothright", "fadegrays"]

# on-screen text goes through Pillow, which cannot draw colour emoji -- these stay plain.
# Deep enough that one run never repeats a line: three variants eat ~20 of them.
CAPTIONS = {
    # alternating tease / payoff, so any contiguous slice still reads as a build-up
    "ru": [
        "СМОТРИ ДО КОНЦА",
        "ЭТО БЫЛО БОЛЬНО",
        "НЕ МОРГАЙ",
        "ОН В ШОКЕ",
        "СЕЙЧАС БУДЕТ",
        "ЛАСТ ХИТ",
        "А ТЕПЕРЬ ВНИМАНИЕ",
        "НУ И КАК ТЕБЕ",
        "ВОТ ЭТОТ МОМЕНТ",
        "ОН НЕ УСПЕЛ",
        "ОН ЕЩЁ НЕ ПОНЯЛ",
        "ТЫ ЭТО ВИДЕЛ",
        "ДАЛЬШЕ ХУЖЕ",
        "ТУТ ОН СЛОМАЛСЯ",
        "ЭТО ЕЩЁ НЕ ВСЁ",
        "НИКТО НЕ ОЖИДАЛ",
        "ДЕРЖИСЬ",
        "ОН ДУМАЛ ЧТО ВЫИГРАЛ",
        "ВОТ ТУТ НАЧАЛОСЬ",
        "БЕЗ ШАНСОВ",
        "ВОТ ЗАЧЕМ ТЫ ЗДЕСЬ",
        "КАК ОН ВЫЖИЛ",
        "ЗАПОМНИ ЭТОТ КАДР",
        "ЭТО ВООБЩЕ ЛЕГАЛЬНО",
        "СЕКУНДА РЕШИЛА ВСЁ",
        "ПЕРЕМОТАЙ И ГЛЯНЬ",
        "ЭТО КОНЕЦ",
        "Я ПЕРЕСМОТРЕЛ 10 РАЗ",
        "ПОПРОБУЙ ПОВТОРИ",
        "ГГ",
    ],
    "en": [
        "WATCH TILL THE END",
        "THAT HURT",
        "DO NOT BLINK",
        "HE IS DONE",
        "HERE IT COMES",
        "LAST HIT",
        "NOW WATCH THIS",
        "HOW WAS THAT",
        "THIS IS THE MOMENT",
        "TOO LATE",
        "HE HAS NO IDEA",
        "DID YOU SEE THAT",
        "IT GETS WORSE",
        "HERE HE BROKE",
        "NOT DONE YET",
        "NOBODY SAW IT",
        "HOLD ON",
        "HE THOUGHT HE WON",
        "IT STARTS HERE",
        "NO CHANCE",
        "THIS IS WHY YOU CAME",
        "HOW DID HE LIVE",
        "REMEMBER THIS FRAME",
        "IS THIS EVEN LEGAL",
        "ONE SECOND DECIDED IT",
        "REWIND AND LOOK",
        "THIS IS THE END",
        "I REWATCHED IT TEN TIMES",
        "TRY TO REPEAT THAT",
        "GG",
    ],
}

# never drawn, only spoken -- so these are written the way they are said, not shouted.
# Short: they land on the tail of a moment and must be over before the next one.
ADLIBS = {
    "ru": [
        "Ох ты ж!",
        "Ай-ай-ай...",
        "Ну ты даёшь!",
        "Э, куда собрался?!",
        "Во! Вот это дед понимает!",
        "Ну-ну... ну-ну.",
        "В моё время так не умели!",
        "Тьфу ты, ну!",
        "Спокойно. Я всё видел.",
        "Ох, батюшки-и...",
        "Молодец, внучек!",
        "Ну всё. Финиш.",
        "Я аж привстал!",
        "Не смотри... там страшно.",
        "Вот так вот, да!",
        "Ай, красиво-о!",
    ],
    "en": [
        "Oh boy!",
        "Well, well...",
        "Easy now!",
        "Hey! Where do you think you are going?!",
        "Back in my day...",
        "Oh dear-r...",
        "Not bad, kid!",
        "Goodness me!",
        "That is all, folks.",
        "I did warn him!",
        "Hoo boy...",
        "Watch him go!",
        "I nearly stood up!",
        "Do not look... it is scary.",
        "There we go!",
        "Oh, that is nice-e!",
    ],
}

HASHTAGS = {
    "ru": ["#clashroyale", "#клешрояль", "#клэшрояль", "#рекомендации", "#рек", "#игры"],
    "en": ["#clashroyale", "#clash", "#royale", "#gaming", "#fyp", "#clutch"],
}


def title_for(lang: str, seed: str) -> str:
    pool = TITLES.get(lang, TITLES["ru"])
    idx = int(hashlib.sha1(seed.encode()).hexdigest(), 16) % len(pool)
    return pool[idx]


def hashtags_for(lang: str) -> list[str]:
    return list(HASHTAGS.get(lang, HASHTAGS["ru"]))


def plain_text(text: str) -> str:
    """Drop emoji: they belong in the .txt sidecar, not in a Pillow-rendered caption."""
    return " ".join("".join(c for c in text if ord(c) < 0x2000).split())
