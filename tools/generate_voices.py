#!/usr/bin/env python3
"""Generate Sandwar's Dune 2000-style spoken radio alerts, locally.

Engine detection, in preference order:
  1. Piper neural TTS -- a local model in tools/voices (or the path in
     SANDWAR_PIPER_MODEL). This is the intended production voice.
  2. pico2wave CLI  (deep, measured; `sudo apt install libttspico-utils`)
  3. espeak-ng CLI  (`sudo apt install espeak-ng`)
  4. espeak CLI
  5. flite CLI
  6. libespeak-ng through ctypes -- this machine has the shared library via
     speech-dispatcher even though the CLI is absent.

With no engine at all the script prints the exact apt command and renders clean
radio-chime placeholders so the game still has distinct alerts.

Every line is then pushed through a gritty 1998 Westwood comms chain:
350-3200 Hz bandpass, tanh saturation + simple companding, a little low-band
"pitch weight", 22050 Hz 16-bit mono, and a 25 ms squelch click at each end.

Output: assets/sfx/voice/*.wav
"""

from __future__ import annotations

import ctypes
import ctypes.util
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

try:
    import numpy as np
except Exception:  # pragma: no cover - numpy is present on the target PC
    np = None

RATE = 22050
ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "sfx" / "voice"
DEFAULT_PIPER_MODEL = ROOT / "tools" / "voices" / "en_GB-alan-medium.onnx"

# File name -> spoken line. Keep this order; it is the game's alert order.
LINES = {
    "enemy_approaching.wav": "Warning. Enemy unit approaching.",
    "base_under_attack.wav": "Our base is under attack.",
    "harvester_under_attack.wav": "Harvester under attack.",
    "construction_complete.wav": "Construction complete.",
    "unit_ready.wav": "Unit ready.",
    "low_power.wav": "Low power.",
    "wormsign.wav": "Warning. Wormsign.",
    "worm_attack.wav": "Warning. Worm attack.",
    "reinforcements.wav": "Reinforcements have arrived.",
}

# Placeholder motifs, used only when no speech engine exists.
CHIMES = {
    "enemy_approaching.wav": [760.0, 610.0, 480.0],
    "base_under_attack.wav": [440.0, 330.0, 440.0],
    "harvester_under_attack.wav": [620.0, 500.0],
    "construction_complete.wav": [520.0, 660.0, 780.0],
    "unit_ready.wav": [660.0, 880.0],
    "low_power.wav": [300.0, 240.0],
    "wormsign.wav": [880.0, 700.0, 560.0, 440.0],
    "worm_attack.wav": [220.0, 180.0, 150.0],
    "reinforcements.wav": [520.0, 620.0, 740.0, 880.0],
}


# ------------------------------------------------------------------ engines

def find_engine():
    """Return (kind, handle) for the best available local TTS engine."""
    piper_exe = shutil.which("piper")
    if not piper_exe:
        local_piper = ROOT / ".tools-venv" / "bin" / "piper"
        if local_piper.exists():
            piper_exe = str(local_piper)
    model = Path(os.environ.get("SANDWAR_PIPER_MODEL", str(DEFAULT_PIPER_MODEL))).expanduser()
    config = Path(str(model) + ".json")
    if piper_exe and model.exists() and config.exists():
        return "piper", (piper_exe, model)
    for name in ("pico2wave", "espeak-ng", "espeak", "flite"):
        path = shutil.which(name)
        if path:
            return name, path
    lib = ctypes.util.find_library("espeak-ng")
    if lib:
        return "espeak-ng-lib", lib
    return None, None


def synth_piper(exe: str, model: Path, text: str):
    """Render one line through a local Piper ONNX voice."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        cmd = [exe, "-m", str(model), "-f", str(tmp_path),
               "--length-scale", "1.10", "--sentence-silence", "0.05"]
        subprocess.run(cmd, input=text.encode("utf-8"), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return read_wav(tmp_path)
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass


def synth_cli(kind: str, exe: str, text: str):
    """Render one line with a CLI engine, return (float samples, rate)."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        if kind == "pico2wave":
            cmd = [exe, "-l", "en-GB", "-w", str(tmp_path), text]
        elif kind in ("espeak-ng", "espeak"):
            # Slow, low and deliberate: the measured mission-control voice.
            cmd = [exe, "-v", "en-gb", "-s", "138", "-p", "32", "-a", "180",
                   "-w", str(tmp_path), text]
        else:  # flite
            cmd = [exe, "-t", text, "-o", str(tmp_path)]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE)
        return read_wav(tmp_path)
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass


def synth_lib(lib_path: str, text: str):
    """Render one line through libespeak-ng with a synth callback."""
    lib = ctypes.CDLL(lib_path)
    lib.espeak_Initialize.restype = ctypes.c_int
    rate = lib.espeak_Initialize(2, 500, None, 0)  # AUDIO_OUTPUT_RETRIEVAL
    if rate <= 0:
        raise RuntimeError("espeak_Initialize failed")

    chunks = []
    cb_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.POINTER(ctypes.c_short),
                               ctypes.c_int, ctypes.c_void_p)

    def _collect(wav, count, _events):
        if wav and count > 0:
            chunks.append(ctypes.string_at(wav, count * 2))
        return 0

    callback = cb_type(_collect)
    lib.espeak_SetSynthCallback.argtypes = [cb_type]
    lib.espeak_SetSynthCallback(callback)

    voice = "default"
    for candidate in ("en-gb", "en", "english", "gmw/en"):
        if lib.espeak_SetVoiceByName(candidate.encode("ascii")) == 0:
            voice = candidate
            break

    lib.espeak_SetParameter(1, 138, 0)  # rate (words/min)
    lib.espeak_SetParameter(3, 32, 0)   # pitch, deep
    lib.espeak_SetParameter(4, 42, 0)   # pitch range, narrow and even
    lib.espeak_Synth.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint,
                                 ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                                 ctypes.c_void_p, ctypes.c_void_p]
    raw = text.encode("utf-8")
    if lib.espeak_Synth(raw, len(raw) + 1, 0, 1, 0, 0, None, None) != 0:
        raise RuntimeError("espeak_Synth failed")
    lib.espeak_Synchronize()
    data = b"".join(chunks)
    if not data:
        raise RuntimeError("espeak produced no audio")
    samples = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0
    return samples, rate, voice


def synth_line(kind: str, handle, text: str):
    if kind == "piper":
        samples, rate = synth_piper(handle[0], handle[1], text)
        return samples, rate, "piper"
    if kind == "espeak-ng-lib":
        return synth_lib(handle, text)
    samples, rate = synth_cli(kind, handle, text)
    return samples, rate, kind


# ------------------------------------------------------------------ wav i/o

def read_wav(path: Path):
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())
    if width != 2:
        raise RuntimeError(f"{path.name}: expected 16-bit PCM")
    data = np.frombuffer(frames, dtype="<i2").astype(np.float64) / 32768.0
    if channels == 2:
        data = data.reshape(-1, 2).mean(axis=1)
    return data, rate


def write_wav(path: Path, samples) -> tuple[float, float, float]:
    values = np.asarray(samples, dtype=np.float64)
    values = np.clip(values, -1.0, 1.0)
    peak = float(np.max(np.abs(values))) if len(values) else 0.0
    rms = float(np.sqrt(np.mean(values * values))) if len(values) else 0.0
    pcm = (values * 32767.0).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(pcm)
    return peak, rms, len(values) / RATE


# ------------------------------------------------------------------ DSP

def resample(x, src_rate: int, dst_rate: int = RATE):
    if src_rate == dst_rate or len(x) == 0:
        return x
    count = max(1, int(round(len(x) * dst_rate / src_rate)))
    src_t = np.linspace(0.0, 1.0, len(x), endpoint=False)
    dst_t = np.linspace(0.0, 1.0, count, endpoint=False)
    return np.interp(dst_t, src_t, x)


def bandpass(x, lo: float = 350.0, hi: float = 3200.0, sr: int = RATE):
    """FFT bandpass with soft shoulders, so the comms band is clean, not harsh."""
    if len(x) < 8:
        return x
    spectrum = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(len(x), 1.0 / sr)
    mask = np.ones_like(freqs)
    mask[freqs < lo] = 0.0
    mask[freqs > hi] = 0.0
    lo_edge = (freqs >= lo) & (freqs < lo + 90.0)
    mask[lo_edge] = 0.5 - 0.5 * np.cos(np.pi * (freqs[lo_edge] - lo) / 90.0)
    hi_edge = (freqs > hi - 420.0) & (freqs <= hi)
    mask[hi_edge] = 0.5 + 0.5 * np.cos(np.pi * (freqs[hi_edge] - (hi - 420.0)) / 420.0)
    return np.fft.irfft(spectrum * mask, len(x))


def compress(x, threshold: float = 0.20, ratio: float = 3.2,
             attack: float = 0.006, release: float = 0.12):
    """One-pole peak follower + gentle gain reduction: classic radio companding."""
    env = np.abs(x)
    smooth = np.empty_like(env)
    a_att = math.exp(-1.0 / (attack * RATE))
    a_rel = math.exp(-1.0 / (release * RATE))
    level = 0.0
    for i in range(len(env)):
        v = float(env[i])
        coeff = a_att if v > level else a_rel
        level = coeff * level + (1.0 - coeff) * v
        smooth[i] = level
    gain = np.ones_like(x)
    over = smooth > threshold
    gain[over] = (threshold + (smooth[over] - threshold) / ratio) / smooth[over]
    return x * gain


def normalize(x, peak: float = 0.89):
    top = float(np.max(np.abs(x))) if len(x) else 0.0
    if top < 1e-8:
        return x
    return x / top * peak


def radio_dsp(x):
    """The 1998 Westwood comms chain."""
    x = x - float(np.mean(x))
    x = normalize(x, 1.0)
    x = bandpass(x)
    # Slight pitch weight: lift the 300-900 Hz body and add a soft sub-octave
    # exciter, which reads as a bigger chest without changing the words.
    body = bandpass(x, 300.0, 900.0)
    x = x + body * 0.34
    x = x + np.tanh(x * 3.0) * 0.05
    # Saturation, then companding, then a final bandpass after the harmonics.
    x = np.tanh(x * 2.15) / math.tanh(2.15)
    x = compress(x)
    x = bandpass(x)
    x = normalize(x, 0.92)
    return x


def squelch(duration: float = 0.025):
    """Crisp tactical radio click: noise transient + short 1.75 kHz tick."""
    t = np.arange(max(2, int(duration * RATE)), dtype=np.float64) / RATE
    rng = np.random.default_rng(1998)
    click = rng.normal(0.0, 1.0, len(t)) * np.exp(-t / 0.0035) * 0.75
    tick = np.sin(2.0 * math.pi * 1750.0 * t) * np.exp(-t / 0.005) * 0.35
    click = bandpass(click + tick, 300.0, 3600.0)
    return normalize(click, 0.17)


def assemble(speech):
    gap = np.zeros(int(0.03 * RATE), dtype=np.float64)
    click = squelch()
    return np.concatenate([click, gap, speech, gap, click])


def render_chime(frequencies):
    """Placeholder motif when no TTS engine is installed."""
    rng = np.random.default_rng(abs(hash(tuple(frequencies))) & 0xFFFF)
    pieces = []
    note_len = 0.15
    for i, freq in enumerate(frequencies):
        t = np.arange(int(note_len * RATE), dtype=np.float64) / RATE
        env = np.minimum(1.0, t / 0.006) * np.exp(-t / 0.055)
        tone = (np.sin(2.0 * math.pi * freq * t) * 0.62
                + np.sin(2.0 * math.pi * freq * 2.0 * t) * 0.16
                + np.sin(2.0 * math.pi * freq * 3.0 * t) * 0.06)
        piece = tone * env
        if i == 0:
            piece += rng.normal(0.0, 1.0, len(t)) * np.exp(-t / 0.004) * 0.20
        pieces.append(piece)
    total = np.concatenate(pieces)
    static = rng.normal(0.0, 1.0, len(total)) * 0.012
    return radio_dsp(assemble(total + static))


# ------------------------------------------------------------------ main

def main() -> int:
    if np is None:
        print("generate_voices: NumPy is required (sudo apt install python3-numpy)",
              file=sys.stderr)
        return 1

    kind, handle = find_engine()
    if os.environ.get("SANDWAR_VOICE_PLACEHOLDER") == "1":
        kind, handle = None, None

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Sandwar voice generator")
    print(f"output: {OUT_DIR}")

    engine_label = "none (placeholder chimes)"
    voice_label = ""
    if kind:
        engine_label = kind
        exe_label = handle[0] if isinstance(handle, tuple) else handle
        if kind == "piper":
            engine_label = f"piper ({Path(handle[1]).stem})"
            voice_label = f"voice={Path(handle[1]).stem}"
        elif kind == "espeak-ng-lib":
            engine_label = "espeak-ng (libespeak-ng.so via ctypes)"
        print(f"engine: {engine_label}  ->  {exe_label}")
    else:
        print("engine: none detected")
        print("  install one with:  sudo apt install espeak-ng")
        print("  (or, for pico2wave: sudo apt install libttspico-utils)")
        print("  (or, for Piper: put an .onnx voice in tools/voices or set SANDWAR_PIPER_MODEL)")
        print("  generating clean radio-chime placeholders for now")

    failures = []
    generated = []
    for filename, text in LINES.items():
        try:
            if kind:
                speech, rate, chosen = synth_line(kind, handle, text)
                if kind == "espeak-ng-lib" and voice_label == "":
                    voice_label = f"voice={chosen}"
                speech = resample(speech, rate)
                speech = radio_dsp(speech)
            else:
                speech = render_chime(CHIMES[filename])
            values = assemble(speech)
            path = OUT_DIR / filename
            peak, rms, duration = write_wav(path, values)
            generated.append(filename)
            print(f"  {filename:28s} {duration:5.2f}s  peak={peak:5.2f}  rms={rms:4.3f}  \"{text}\"")
            if peak < 0.05 or rms < 0.002:
                failures.append(filename)
        except Exception as exc:  # one bad line should not abort the rest
            print(f"  {filename:28s} FAILED: {exc}", file=sys.stderr)
            failures.append(filename)

    if voice_label:
        print(f"engine detail: {voice_label}")
    print(f"generated {len(generated)}/{len(LINES)} WAV files, {RATE} Hz mono 16-bit")
    if failures:
        print("FAILED / silent: " + ", ".join(sorted(set(failures))), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
