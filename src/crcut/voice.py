"""Voice-over for the on-screen captions: macOS `say` speaks them, ffmpeg ages them.

macOS ships exactly one Russian voice (Milena, female), so the grandpa is made
rather than picked -- pitch down 4.3 semitones at unchanged duration, thin the band
the way an old voice thins, add a slow tremor. `crcut --voices` lists what is
installed; more are added in System Settings -> Accessibility -> Spoken Content ->
System Voice -> Manage Voices, and any of them then works via `--voice`.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
from pathlib import Path

SAY = "say"
FFMPEG = "ffmpeg"
SR = 44100
RATE = 150  # words per minute -- an unhurried narrator, not a news reader
PITCH = 0.78  # -4.3 semitones: asetrate lowers it, atempo puts the length back

AGE = (
    f"asetrate={SR}*{PITCH},aresample={SR},atempo={1 / PITCH:.4f},"
    "vibrato=f=4.8:d=0.12,highpass=f=80,lowpass=f=5000,"
    "acompressor=threshold=0.12:ratio=3,volume=1.5,alimiter=limit=0.95"
)

# first one that is actually installed wins; "Grandpa" really ships with macOS
PREFERRED = {"ru": ("Yuri", "Milena"), "en": ("Grandpa", "Alex", "Fred")}

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


def speak(text: str, voice: str, cache_dir: Path) -> Path:
    """One cached wav per phrase -- `say` renders it, the AGE chain makes it old."""
    key = hashlib.sha1(f"{text}|{voice}|{RATE}|{AGE}".encode()).hexdigest()[:16]
    path = cache_dir / f"vo_{key}.wav"
    if path.exists():
        return path

    cache_dir.mkdir(parents=True, exist_ok=True)
    raw = path.with_name(f"raw_{key}.wav")
    subprocess.run(
        [SAY, "-v", voice, "-r", str(RATE), "-o", str(raw),
         "--file-format=WAVE", f"--data-format=LEI16@{SR}", text],
        check=True, capture_output=True,
    )
    subprocess.run(
        [FFMPEG, "-v", "error", "-y", "-i", str(raw), "-af", AGE,
         "-ar", str(SR), "-ac", "1", str(path)],
        check=True, capture_output=True,
    )
    raw.unlink()
    return path
