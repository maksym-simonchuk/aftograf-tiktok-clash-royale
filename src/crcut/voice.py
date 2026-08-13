"""Voice-over for the on-screen captions: macOS `say` speaks them, ffmpeg shapes them.

macOS ships exactly one Russian voice (Milena, female), so the grandpa is made
rather than picked. Pitch shifting is what costs quality here -- `asetrate` +
`atempo` smear the more they move -- so the drop is kept to 3 semitones and the
character comes from everything around it: a warm chest bump, the boxy 500 Hz
scooped out, a de-essed top, a slow tremor and a small room. `--voice-style`
switches the whole recipe.

`crcut --voices` lists what is installed; more are added in System Settings ->
Accessibility -> Spoken Content -> System Voice -> Manage Voices, and any of them
then works via `--voice`. A real male Russian voice (Юрий) lives there too, and
beats any amount of processing on a female one.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

SAY = "say"
FFMPEG = "ffmpeg"
SR = 44100


@dataclass(frozen=True)
class Style:
    """How the narrator sounds: how fast `say` reads, how far the pitch moves, what
    ffmpeg does after."""

    rate: int  # words per minute
    shift: float  # pitch ratio, 1.0 leaves it alone
    chain: str  # -af filter chain applied after the shift


def _shift(ratio: float) -> str:
    """Pitch by `ratio` at unchanged duration -- asetrate moves both, atempo undoes one."""
    return f"asetrate={SR}*{ratio},aresample={SR},atempo={1 / ratio:.4f}"


STYLES = {
    # -3 semitones and old age comes from the body, not from the pitch alone
    "grandpa": Style(140, 0.84, (
        "vibrato=f=4.2:d=0.08,highpass=f=90,lowpass=f=7000,"
        "equalizer=f=220:t=q:w=1.1:g=3,equalizer=f=520:t=q:w=1.4:g=-3,deesser=i=0.4,"
        "aecho=0.85:0.6:24:0.16,acompressor=threshold=0.12:ratio=3,"
        "volume=1.5,alimiter=limit=0.95"
    )),
    # -4 semitones: older and heavier, at the price of audible smearing on long vowels
    "grandpa_deep": Style(132, 0.78, (
        "vibrato=f=4.6:d=0.11,highpass=f=80,lowpass=f=6500,"
        "equalizer=f=190:t=q:w=1.1:g=4,equalizer=f=520:t=q:w=1.4:g=-4,deesser=i=0.5,"
        "aecho=0.85:0.6:32:0.2,acompressor=threshold=0.12:ratio=3,"
        "volume=1.5,alimiter=limit=0.95"
    )),
    # the TikTok commentator: fast, bright, squashed flat so it cuts through music
    "hype": Style(195, 1.05, (
        "highpass=f=120,equalizer=f=2800:t=q:w=1.2:g=3,"
        "equalizer=f=400:t=q:w=1.3:g=-2,deesser=i=0.5,aecho=0.9:0.55:12:0.12,"
        "acompressor=threshold=0.09:ratio=4,volume=1.6,alimiter=limit=0.95"
    )),
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
    )),
    # the voice as macOS made it, only levelled -- no shifting, so no artefacts
    "clean": Style(165, 1.0, (
        "highpass=f=90,deesser=i=0.4,equalizer=f=200:t=q:w=1.2:g=2,"
        "acompressor=threshold=0.12:ratio=3,volume=1.4,alimiter=limit=0.95"
    )),
}
DEFAULT_STYLE = "grandpa"

# first one that is actually installed wins; "Grandpa" really ships with macOS
PREFERRED = {"ru": ("Yuri", "Юрий", "Milena"), "en": ("Grandpa", "Alex", "Fred")}

_LINE = re.compile(r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#")


def available() -> bool:
    return shutil.which(SAY) is not None


def voices() -> list[tuple[str, str]]:
    """(name, locale) of every installed system voice."""
    if not available():
        return []
    out = subprocess.run([SAY, "-v", "?"], capture_output=True, text=True).stdout
    return [(m.group(1), m.group(2)) for m in map(_LINE.match, out.splitlines()) if m]


def pick(lang: str) -> str | None:
    """A preferred voice if one is installed, otherwise any voice of that language.

    Matched by prefix: macOS lists localised names like `Grandpa (Англійська (США))`.
    """
    installed = voices()
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
    """The installed voice the user meant: exact name, or the prefix of one.

    `--voice Grandpa` has to work even though macOS lists it as `Grandpa (...)`,
    and there is one per language -- the one that speaks `lang` wins.
    """
    installed = voices()
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


def speak(text: str, voice: str, cache_dir: Path, style: str = DEFAULT_STYLE) -> Path:
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
