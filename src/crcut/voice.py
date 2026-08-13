"""Voice-over for the on-screen captions: Microsoft's neural voices via edge-tts
speak them, ffmpeg shapes them; macOS `say` is the offline fallback.

edge-tts needs the network the first time a phrase is spoken -- cached after, by a
hash of text+voice+rate+pitch+chain, so a second render never touches it again. Its
voices already sound human, so the ffmpeg chain behind them stays light: a
compressor, a limiter, a highpass, nothing that fights the synthesis. `say` still
gets the old destructive chains, because Milena needs them: macOS ships exactly one
Russian voice (female), so the grandpa there is made rather than picked, and pitch
shifting smears the more it moves.

`crcut --voices` lists edge-tts's curated voices plus whatever `say` has installed;
more `say` voices are added in System Settings -> Accessibility -> Spoken Content ->
System Voice -> Manage Voices. `--voice-style` switches the whole recipe, on either
backend.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SAY = "say"
FFMPEG = "ffmpeg"
SR = 44100


@dataclass(frozen=True)
class Style:
    """How the narrator sounds. `rate`/`shift`/`chain` drive the `say` backend, the
    same way they always have; `edge_rate`/`edge_pitch`/`edge_jitter` drive edge-tts,
    which needs none of `say`'s destructive shaping to stop sounding robotic."""

    rate: int  # words per minute (say)
    shift: float  # pitch ratio, 1.0 leaves it alone (say)
    chain: str  # -af filter chain applied after the shift (say)
    edge_rate: int  # percent rate offset for edge-tts, e.g. -8
    edge_pitch: int  # Hz pitch offset for edge-tts, e.g. -6
    edge_jitter: bool  # per-line jitter like `_recipe` gives `say`; off keeps it flat


def _shift(ratio: float) -> str:
    """Pitch by `ratio` at unchanged duration -- asetrate moves both, atempo undoes one."""
    return f"asetrate={SR}*{ratio},aresample={SR},atempo={1 / ratio:.4f}"


STYLES = {
    # the intriguing narrator: edge-tts's primary style and the new default. Its say
    # fields fall back to a level read -- Milena has no "intriguing" to give
    "story": Style(165, 1.0, (
        "highpass=f=90,deesser=i=0.4,equalizer=f=200:t=q:w=1.2:g=2,"
        "acompressor=threshold=0.12:ratio=3,volume=1.4,alimiter=limit=0.95"
    ), -8, -6, True),
    # -3 semitones and old age comes from the body, not from the pitch alone
    "grandpa": Style(140, 0.84, (
        "vibrato=f=4.2:d=0.08,highpass=f=90,lowpass=f=7000,"
        "equalizer=f=220:t=q:w=1.1:g=3,equalizer=f=520:t=q:w=1.4:g=-3,deesser=i=0.4,"
        "aecho=0.85:0.6:24:0.16,acompressor=threshold=0.12:ratio=3,"
        "volume=1.5,alimiter=limit=0.95"
    ), -12, -10, False),
    # -4 semitones: older and heavier, at the price of audible smearing on long vowels
    "grandpa_deep": Style(132, 0.78, (
        "vibrato=f=4.6:d=0.11,highpass=f=80,lowpass=f=6500,"
        "equalizer=f=190:t=q:w=1.1:g=4,equalizer=f=520:t=q:w=1.4:g=-4,deesser=i=0.5,"
        "aecho=0.85:0.6:32:0.2,acompressor=threshold=0.12:ratio=3,"
        "volume=1.5,alimiter=limit=0.95"
    ), -12, -10, False),
    # the TikTok commentator: fast, bright, squashed flat so it cuts through music
    "hype": Style(195, 1.05, (
        "highpass=f=120,equalizer=f=2800:t=q:w=1.2:g=3,"
        "equalizer=f=400:t=q:w=1.3:g=-2,deesser=i=0.5,aecho=0.9:0.55:12:0.12,"
        "acompressor=threshold=0.09:ratio=4,volume=1.6,alimiter=limit=0.95"
    ), 14, 4, False),
    # the trash-stream caricature: hoarse, nasal, shouted into a cheap mic. A type,
    # not a person -- crcut has no voice model of anybody and clones nobody.
    "rasp": Style(185, 0.90, (
        "highpass=f=150,lowpass=f=6000,"
        "equalizer=f=1400:t=q:w=1.6:g=6,equalizer=f=400:t=q:w=1.2:g=-4,"  # nose
        "acompressor=threshold=0.05:ratio=8,"  # shouting, not talking
        "aexciter=amount=3:blend=2,acrusher=bits=7:mode=log:aa=1,"  # the rasp itself
        # peak, not loudness: the grit is transient-heavy, and at grandpa's gain it
        # pushed the final mix flat against the limiter
        "crystalizer=i=1,volume=1.8,alimiter=limit=0.95"
    ), 14, 4, False),
    # the voice as macOS made it, only levelled -- no shifting, so no artefacts
    "clean": Style(165, 1.0, (
        "highpass=f=90,deesser=i=0.4,equalizer=f=200:t=q:w=1.2:g=2,"
        "acompressor=threshold=0.12:ratio=3,volume=1.4,alimiter=limit=0.95"
    ), 0, 0, False),
}
DEFAULT_STYLE = "story"

# first one that is actually installed wins; "Grandpa" really ships with macOS
PREFERRED = {"ru": ("Yuri", "Юрий", "Milena"), "en": ("Grandpa", "Alex", "Fred")}

# curated Microsoft neural voices, primary first; full Azure ids, e.g.
# `ru-RU-DmitryNeural` -- no lookup call, edge-tts ships thousands we never need
EDGE_VOICES: dict[str, tuple[str, ...]] = {
    "ru": ("ru-RU-DmitryNeural", "ru-RU-SvetlanaNeural"),
    "en": ("en-US-AndrewMultilingualNeural", "en-US-BrianMultilingualNeural"),
}

# compressor + limiter + highpass only: these voices already sound human, so nothing
# here fights the synthesis the way the `say` chains have to
EDGE_CHAIN = "highpass=f=100,acompressor=threshold=0.1:ratio=3,volume=1.5,alimiter=limit=0.95"

_LINE = re.compile(r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#")
_EDGE_NAME = re.compile(r"^[a-z]{2,3}-[A-Z]{2}-\w+Neural$")
_BARE_NAME = re.compile(r"^[a-z]{2,3}-[A-Z]{2}-(.+?)(?:Multilingual)?Neural$")

_EDGE_OK: bool | None = None


def _edge_ok() -> bool:
    """Whether edge-tts is importable -- checked once per process and cached. Not a
    network probe: the package can be installed on a machine with no internet, and
    the actual network use only happens (and only fails) in `_edge_synth`."""
    global _EDGE_OK
    if _EDGE_OK is None:
        try:
            import edge_tts  # noqa: F401
            _EDGE_OK = True
        except ImportError:
            _EDGE_OK = False
    return _EDGE_OK


def _bare_name(voice_id: str) -> str:
    """`ru-RU-DmitryNeural` -> `Dmitry`, `en-US-AndrewMultilingualNeural` -> `Andrew`."""
    m = _BARE_NAME.match(voice_id)
    return m.group(1) if m else voice_id


def _locale(voice_id: str) -> str:
    """`ru-RU-DmitryNeural` -> `ru_RU`, matching the `xx_XX` shape `say -v ?` uses so
    `pick`/`resolve`'s `locale.startswith(lang)` checks work on either backend."""
    lang, region, _name = voice_id.split("-", 2)
    return f"{lang}_{region}"


def _is_edge_voice(name: str) -> bool:
    """True for a full Microsoft neural voice id, or a prefix/bare-name match of one
    in EDGE_VOICES (`Dmitry`); false for a `say` voice name."""
    if _EDGE_NAME.match(name):
        return True
    candidates = [v for vs in EDGE_VOICES.values() for v in vs]
    n = name.lower()
    return any(v.lower().startswith(n) or _bare_name(v).lower().startswith(n) for v in candidates)


def available() -> bool:
    return _edge_ok() or shutil.which(SAY) is not None


def _say_voices() -> list[tuple[str, str]]:
    """(name, locale) of every installed macOS system voice."""
    if not shutil.which(SAY):
        return []
    out = subprocess.run([SAY, "-v", "?"], capture_output=True, text=True).stdout
    return [(m.group(1), m.group(2)) for m in map(_LINE.match, out.splitlines()) if m]


def voices() -> list[tuple[str, str]]:
    """(name, locale) of every voice `speak` can use: the curated edge-tts voices
    first (no network call -- just the constant), then whatever `say` has installed."""
    edge = [(v, _locale(v)) for vs in EDGE_VOICES.values() for v in vs] if _edge_ok() else []
    return edge + _say_voices()


def pick(lang: str) -> str | None:
    """The primary edge-tts voice for `lang` if edge-tts is installed, else the
    preferred installed `say` voice."""
    if _edge_ok() and lang in EDGE_VOICES:
        return EDGE_VOICES[lang][0]
    return _pick_say(lang)


def _pick_say(lang: str) -> str | None:
    """A preferred `say` voice if one is installed, otherwise any voice of that
    language.

    Matched by prefix: macOS lists localised names like `Grandpa (Англійська (США))`.
    """
    installed = _say_voices()
    for wanted in PREFERRED.get(lang, ()):
        for name, locale in installed:
            # locale too: macOS installs a Grandpa per language, and the German one
            # reading English captions is not the joke we are after
            if locale.startswith(lang) and name.startswith(wanted):
                return name
    for name, locale in installed:
        if locale.startswith(lang):
            return name
    return None


def resolve(wanted: str, lang: str = "") -> str | None:
    """The voice the user meant: an edge-tts neural voice by exact id, prefix or bare
    name (`Dmitry` -> `ru-RU-DmitryNeural`) if one matches, else an installed `say`
    voice."""
    return _resolve_edge(wanted, lang) or _resolve_say(wanted, lang)


def _resolve_edge(wanted: str, lang: str) -> str | None:
    if not _edge_ok():
        return None
    candidates = [v for vs in EDGE_VOICES.values() for v in vs]
    w = wanted.lower()
    exact = [v for v in candidates if v.lower() == w]
    if exact:
        return exact[0]
    matches = [v for v in candidates
               if v.lower().startswith(w) or _bare_name(v).lower().startswith(w)]
    for v in matches:
        if v.startswith(f"{lang}-"):
            return v
    return matches[0] if matches else None


def _resolve_say(wanted: str, lang: str = "") -> str | None:
    """The installed `say` voice the user meant: exact name, or the prefix of one.

    `--voice Grandpa` has to work even though macOS lists it as `Grandpa (...)`,
    and there is one per language -- the one that speaks `lang` wins.
    """
    installed = _say_voices()
    if any(name == wanted for name, _ in installed):
        return wanted
    matches = [(name, loc) for name, loc in installed if name.startswith(wanted)]
    for name, locale in matches:
        if locale.startswith(lang):
            return name
    return matches[0][0] if matches else None


def _recipe(style: str, text: str) -> tuple[int, str]:
    """The style, nudged a little for this particular phrase.

    Reading every line at exactly one pitch and one speed is what gives a synthetic
    narrator away -- a person never repeats themselves that precisely. The nudge is
    derived from the text, so it is stable across runs (the cache still hits) and
    different between neighbouring lines, which is the whole point. It stays small
    enough that it is still the same old man talking.
    """
    base = STYLES.get(style, STYLES[DEFAULT_STYLE])
    seed = int(hashlib.sha1(text.encode()).hexdigest()[:8], 16)
    rate = base.rate + (seed % 5 - 2) * 6  # +-12 wpm
    if base.shift == 1.0:  # `clean` promises no shifting, so it gets none
        return rate, base.chain
    ratio = base.shift * (1.0 + ((seed >> 8) % 5 - 2) * 0.012)  # +-2.4%
    return rate, f"{_shift(ratio)},{base.chain}"


def _edge_recipe(style: str, text: str) -> tuple[int, int]:
    """Rate/pitch offsets for edge-tts, nudged per-phrase the same way `_recipe`
    nudges `say`: identical prosody on every line is what flags a synthetic
    narrator, and deriving the nudge from the text keeps it stable across runs (the
    cache still hits) while varying between neighbouring lines."""
    base = STYLES.get(style, STYLES[DEFAULT_STYLE])
    if not base.edge_jitter:
        return base.edge_rate, base.edge_pitch
    seed = int(hashlib.sha1(text.encode()).hexdigest()[:8], 16)
    rate = base.edge_rate + (seed % 9 - 4)  # +-4%
    pitch = base.edge_pitch + ((seed >> 8) % 7 - 3)  # +-3Hz
    return rate, pitch


def speak(text: str, voice: str, cache_dir: Path, style: str = DEFAULT_STYLE) -> Path:
    """One cached wav per phrase. `voice` naming a Microsoft neural voice renders it
    through edge-tts; anything else (or an edge-tts failure) goes through `say`."""
    if _is_edge_voice(voice):
        try:
            return _speak_edge(text, voice, cache_dir, style)
        except Exception as exc:  # network down, DNS, service error -- a render
            # must not die just because the network did; fall back and say why
            print(f"voice: edge-tts failed ({exc}), falling back to say", file=sys.stderr)
            lang = voice.split("-", 1)[0]
            say_voice = _pick_say(lang)
            if say_voice:
                return _speak_say(text, say_voice, cache_dir, style)
            raise
    return _speak_say(text, voice, cache_dir, style)


def _speak_say(text: str, voice: str, cache_dir: Path, style: str = DEFAULT_STYLE) -> Path:
    """One cached wav per phrase -- `say` renders it, the style shapes it."""
    rate, chain = _recipe(style, text)
    key = hashlib.sha1(f"{text}|{voice}|{rate}|{chain}".encode()).hexdigest()[:16]
    path = cache_dir / f"vo_{key}.wav"
    if path.exists():
        return path

    cache_dir.mkdir(parents=True, exist_ok=True)
    raw = path.with_name(f"raw_{key}.wav")
    subprocess.run(
        [SAY, "-v", voice, "-r", str(rate), "-o", str(raw),
         "--file-format=WAVE", f"--data-format=LEI16@{SR}", text],
        check=True, capture_output=True,
    )
    subprocess.run(
        [FFMPEG, "-v", "error", "-y", "-i", str(raw), "-af", chain,
         "-ar", str(SR), "-ac", "1", str(path)],
        check=True, capture_output=True,
    )
    raw.unlink()
    return path


def _speak_edge(text: str, voice: str, cache_dir: Path, style: str) -> Path:
    """One cached wav per phrase -- edge-tts renders it, a light chain levels it."""
    rate, pitch = _edge_recipe(style, text)
    key = hashlib.sha1(
        f"edge|{text}|{voice}|{rate}|{pitch}|{EDGE_CHAIN}".encode()
    ).hexdigest()[:16]
    path = cache_dir / f"vo_{key}.wav"
    if path.exists():  # the normal path -- no network touched once a phrase is cached
        return path

    cache_dir.mkdir(parents=True, exist_ok=True)
    raw = path.with_name(f"raw_{key}.mp3")
    try:
        _edge_synth(text, voice, rate, pitch, raw)
        subprocess.run(
            [FFMPEG, "-v", "error", "-y", "-i", str(raw), "-af", EDGE_CHAIN,
             "-ar", str(SR), "-ac", "1", str(path)],
            check=True, capture_output=True,
        )
    finally:
        # a failed synth can still leave a partial download behind, and that must
        # not linger in the cache dir -- only `path` existing means success
        raw.unlink(missing_ok=True)
    return path


def _edge_synth(text: str, voice: str, rate: int, pitch: int, out: Path) -> None:
    """The network call, isolated so tests can fake it without reaching Microsoft."""
    import asyncio

    import edge_tts

    communicate = edge_tts.Communicate(text, voice, rate=f"{rate:+d}%", pitch=f"{pitch:+d}Hz")
    if hasattr(communicate, "save_sync"):
        communicate.save_sync(str(out))
    else:
        asyncio.run(communicate.save(str(out)))
