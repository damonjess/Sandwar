#!/usr/bin/env python3
"""Generate all Mentat briefings and EVA alerts with Piper, locally.

Sources:
    data/missions.gd  -> MENTAT_ORDERS (7 missions x 3 Houses)

Voices:
    Atreides  Thufir Hawat       en_GB-alan-medium, measured and dignified
    Harkonnen Piter de Vries     northern English male, pitched down and gritty
    Ordos     The Executrix      US male model, ring-mod / chorus cybernetics
    EVA       tactical computer  en_GB-alan-medium, tighter and brighter

Every take is run through a 1998 Westwood radio chain: 320-3400 Hz bandpass,
gentle companding and warmth, a whisper of channel noise, and a short squelch
click at each end. Output is compact mono Ogg Vorbis:

    assets/sfx/mentat/<house>_mission_<NN>.ogg
    assets/sfx/voice/<alert>.ogg
"""

from __future__ import annotations

import ast
import math
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

try:
    import numpy as np
    from scipy.signal import butter, lfilter, sosfilt
except Exception as exc:  # pragma: no cover - target venv has both
    print(f"generate_mentat_voices: missing dependency: {exc}", file=sys.stderr)
    print("  install with: .tools-venv/bin/pip install numpy scipy", file=sys.stderr)
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent
MISSIONS_FILE = ROOT / "data" / "missions.gd"
VOICE_DIR = ROOT / "tools" / "voices"
MENTAT_OUT = ROOT / "assets" / "sfx" / "mentat"
VOICE_OUT = ROOT / "assets" / "sfx" / "voice"
RATE = 22050

HOUSES = {
    "atreides": {
        "model": "en_GB-alan-medium.onnx",
        "length": 1.10,
        "pitch": 0.98,
        "band": (320.0, 3400.0),
        "drive": 1.8,
        "comp": 2.8,
        "grit": 0.0,
        "ring": 0.0,
        "warmth": 0.22,
    },
    "harkonnen": {
        "model": "en_GB-northern_english_male-medium.onnx",
        "length": 0.98,
        "pitch": 0.86,
        "band": (290.0, 3100.0),
        "drive": 3.1,
        "comp": 3.8,
        "grit": 0.20,
        "ring": 0.0,
        "warmth": 0.34,
    },
    "ordos": {
        "model": "en_US-ryan-medium.onnx",
        "length": 1.03,
        "pitch": 1.01,
        "band": (390.0, 3000.0),
        "drive": 1.6,
        "comp": 3.1,
        "grit": 0.0,
        "ring": 0.09,
        "warmth": 0.12,
    },
}

EVA = {
    "model": "en_GB-alan-medium.onnx",
    "length": 0.95,
    "pitch": 1.0,
    "band": (320.0, 3600.0),
    "drive": 1.55,
    "comp": 2.3,
    "grit": 0.0,
    "ring": 0.0,
    "warmth": 0.08,
}

# Dune 2000 alert set, including the five upcoming lines. Keeping this order
# stable means the generated folder and AudioManager dictionary stay aligned.
VOICE_LINES = {
    "enemy_approaching": "Warning. Enemy unit approaching.",
    "base_under_attack": "Our base is under attack.",
    "harvester_under_attack": "Harvester under attack.",
    "construction_complete": "Construction complete.",
    "unit_ready": "Unit ready.",
    "low_power": "Low power.",
    "wormsign": "Warning. Wormsign.",
    "worm_attack": "Warning. Worm attack.",
    "reinforcements": "Reinforcements have arrived.",
    "silos_needed": "Silos needed.",
    "radar_online": "Radar online.",
    "radar_offline": "Radar offline.",
    "frigate_arrived": "Frigate arrived.",
    "death_hand_launched": "Warning. Death Hand launched.",
}


# ------------------------------------------------------------------ text

def load_mentat_orders() -> dict[str, list[str]]:
    text = MISSIONS_FILE.read_text(encoding="utf-8")
    match = re.search(
        r"const MENTAT_ORDERS\s*:=\s*(\{.*?\n\})\s*\n\nconst TIER_TEMPLATES",
        text,
        re.S,
    )
    if not match:
        raise RuntimeError("could not find MENTAT_ORDERS in data/missions.gd")
    raw = ast.literal_eval(match.group(1))
    orders: dict[str, list[str]] = {}
    for house in ("atreides", "harkonnen", "ordos"):
        values = raw.get(house)
        if not isinstance(values, list) or len(values) != 7:
            raise RuntimeError(f"{house}: expected 7 Mentat orders, got {values!r}")
        orders[house] = [str(line).strip() for line in values]
        if any(len(line) < 80 for line in orders[house]):
            raise RuntimeError(f"{house}: found an empty or truncated briefing")
    return orders


# ------------------------------------------------------------------ piper

def synth(text: str, model: Path, length_scale: float) -> tuple[np.ndarray, int]:
    if not model.exists():
        raise FileNotFoundError(f"Piper voice missing: {model}")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        cmd = [
            sys.executable, "-m", "piper",
            "-m", str(model), "-f", str(tmp_path),
            "--length-scale", f"{length_scale:.3f}",
            "--sentence-silence", "0.06",
        ]
        result = subprocess.run(
            cmd, input=text.encode("utf-8"), check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.decode("utf-8", "replace").strip() or "piper failed")
        with wave.open(str(tmp_path), "rb") as wav:
            channels = wav.getnchannels()
            width = wav.getsampwidth()
            rate = wav.getframerate()
            frames = wav.readframes(wav.getnframes())
        if width != 2:
            raise RuntimeError("Piper produced non-16-bit audio")
        data = np.frombuffer(frames, dtype="<i2").astype(np.float64) / 32768.0
        if channels == 2:
            data = data.reshape(-1, 2).mean(axis=1)
        return data, rate
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass


# ------------------------------------------------------------------ DSP

def bandpass(x: np.ndarray, lo: float, hi: float, rate: int) -> np.ndarray:
    nyquist = rate * 0.5
    low = max(20.0, lo) / nyquist
    high = min(nyquist * 0.98, hi) / nyquist
    sos = butter(4, [low, high], btype="bandpass", output="sos")
    return sosfilt(sos, x)


def lowpass(x: np.ndarray, cutoff: float, rate: int) -> np.ndarray:
    sos = butter(2, max(20.0, cutoff) / (rate * 0.5), btype="lowpass", output="sos")
    return sosfilt(sos, x)


def pitch_shift(x: np.ndarray, factor: float) -> np.ndarray:
    """Resample in place: values below 1.0 lower pitch and lengthen the take."""
    if abs(factor - 1.0) < 0.001 or len(x) < 8:
        return x
    new_length = max(8, int(round(len(x) / factor)))
    old_t = np.linspace(0.0, 1.0, len(x), endpoint=False)
    new_t = np.linspace(0.0, 1.0, new_length, endpoint=False)
    return np.interp(new_t, old_t, x)


def compress(x: np.ndarray, rate: int, threshold: float = 0.18,
             ratio: float = 3.0, release: float = 0.10) -> np.ndarray:
    """Fixed-release peak compressor for the radio companding effect."""
    env = np.abs(x)
    coeff = math.exp(-1.0 / max(1.0, release * rate))
    smooth = lfilter([1.0 - coeff], [1.0, -coeff], env)
    gain = np.ones_like(x)
    over = smooth > threshold
    gain[over] = (threshold + (smooth[over] - threshold) / ratio) / smooth[over]
    return x * gain


def normalize(x: np.ndarray, peak: float = 0.92) -> np.ndarray:
    top = float(np.max(np.abs(x))) if len(x) else 0.0
    if top < 1e-8:
        return x
    return x / top * peak


def cyber_filter(x: np.ndarray, rate: int) -> np.ndarray:
    """Subtle ring-mod + short metallic double for the Executrix."""
    t = np.arange(len(x), dtype=np.float64) / rate
    mod = 1.0 - 0.085 + 0.085 * np.sin(2.0 * math.pi * 37.0 * t)
    x = x * mod
    # Two very short delayed copies read as a cold vocoder/chorus, not a robot
    # that is impossible to understand.
    for delay_s, amount in ((0.011, 0.13), (0.023, 0.07)):
        delay = int(delay_s * rate)
        if delay < len(x):
            delayed = np.concatenate([np.zeros(delay), x[:-delay]])
            x = x + delayed * amount
    # A faint 1.2 kHz resonator adds the metallic edge.
    resonator = bandpass(x, 1000.0, 1500.0, rate) * 0.07
    return x + resonator


def radio_chain(speech: np.ndarray, rate: int, cfg: dict) -> np.ndarray:
    x = speech.astype(np.float64)
    x = x - float(np.mean(x))
    x = normalize(x, 1.0)
    x = bandpass(x, 290.0, 3800.0, rate)

    # House-specific character.
    if cfg.get("ring", 0.0) > 0.0:
        x = cyber_filter(x, rate)
    if cfg.get("grit", 0.0) > 0.0:
        low = lowpass(x, 950.0, rate)
        x = np.tanh(x * (1.0 + cfg["drive"])) / math.tanh(1.0 + cfg["drive"])
        x = x + low * cfg["grit"] * 0.9
    x = x + lowpass(x, 520.0, rate) * cfg.get("warmth", 0.0)

    # 1998 tactical radio: drive, compand, then the final band limit.
    drive = cfg.get("drive", 1.8)
    x = np.tanh(x * drive) / math.tanh(drive)
    x = compress(x, rate, threshold=0.19, ratio=cfg.get("comp", 3.0), release=0.09)
    x = bandpass(x, cfg["band"][0], cfg["band"][1], rate)
    # Very low channel noise gives the line life without hurting intelligibility.
    rng = np.random.default_rng(1998)
    noise = rng.normal(0.0, 1.0, len(x))
    noise = bandpass(noise, 500.0, 2400.0, rate) * 0.0016
    x = x + noise
    return normalize(x, 0.91)


def squelch(rate: int, duration: float = 0.024) -> np.ndarray:
    t = np.arange(max(2, int(duration * rate)), dtype=np.float64) / rate
    rng = np.random.default_rng(2000)
    click = rng.normal(0.0, 1.0, len(t)) * np.exp(-t / 0.0032) * 0.7
    tick = np.sin(2.0 * math.pi * 1750.0 * t) * np.exp(-t / 0.0045) * 0.3
    return normalize(bandpass(click + tick, 300.0, 3600.0, rate), 0.15)


def assemble(speech: np.ndarray, rate: int) -> np.ndarray:
    gap = np.zeros(int(0.03 * rate), dtype=np.float64)
    click = squelch(rate)
    return np.concatenate([click, gap, speech, gap, click])


# ------------------------------------------------------------------ encode

def write_temp_wav(samples: np.ndarray, rate: int, path: Path) -> None:
    pcm = (np.clip(samples, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(pcm)


def encode_ogg(samples: np.ndarray, rate: int, out_path: Path) -> tuple[float, int]:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise FileNotFoundError("ffmpeg is required")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        write_temp_wav(samples, rate, tmp_path)
        result = subprocess.run(
            [ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
             "-i", str(tmp_path),
             "-af", "alimiter=limit=0.95",
             "-ar", str(rate), "-ac", "1", "-c:a", "libvorbis", "-q:a", "3",
             str(out_path)],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.decode("utf-8", "replace").strip())
    finally:
        try:
            tmp_path.unlink()
        except OSError:
            pass
    if not out_path.exists() or out_path.stat().st_size < 1024:
        raise RuntimeError(f"{out_path.name}: encoder produced an empty file")
    if out_path.read_bytes()[:4] != b"OggS":
        raise RuntimeError(f"{out_path.name}: not an Ogg stream")
    duration = 0.0
    ffprobe = shutil.which("ffprobe")
    if ffprobe:
        probe = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(out_path)],
            check=True, capture_output=True, text=True,
        )
        duration = float(probe.stdout.strip() or 0.0)
    return duration, out_path.stat().st_size


def render_voice(text: str, cfg: dict, out_path: Path) -> tuple[float, int]:
    model = VOICE_DIR / cfg["model"]
    speech, rate = synth(text, model, cfg["length"])
    speech = pitch_shift(speech, cfg["pitch"])
    # Piper models are 22.05 kHz; keep a single rate for the whole asset set.
    if rate != RATE:
        speech = np.interp(
            np.linspace(0.0, 1.0, max(1, int(len(speech) * RATE / rate)), endpoint=False),
            np.linspace(0.0, 1.0, len(speech), endpoint=False),
            speech,
        )
        rate = RATE
    speech = radio_chain(speech, rate, cfg)
    values = assemble(speech, rate)
    return encode_ogg(values, rate, out_path)


# ------------------------------------------------------------------ main

def main() -> int:
    if not MISSIONS_FILE.exists():
        print(f"missing {MISSIONS_FILE}", file=sys.stderr)
        return 1
    try:
        orders = load_mentat_orders()
    except Exception as exc:
        print(f"could not load briefings: {exc}", file=sys.stderr)
        return 1

    MENTAT_OUT.mkdir(parents=True, exist_ok=True)
    VOICE_OUT.mkdir(parents=True, exist_ok=True)
    print("Sandwar Mentat / EVA voice generator")
    print(f"mentat output: {MENTAT_OUT}")
    print(f"voice output:  {VOICE_OUT}")

    failures: list[str] = []
    total_bytes = 0
    total_seconds = 0.0

    for house in ("atreides", "harkonnen", "ordos"):
        cfg = HOUSES[house]
        print(f"\n{house.upper()}  voice={Path(cfg['model']).stem}")
        for tier, text in enumerate(orders[house], start=1):
            name = f"{house}_mission_{tier:02d}.ogg"
            try:
                duration, size = render_voice(text, cfg, MENTAT_OUT / name)
                total_bytes += size
                total_seconds += duration
                print(f"  {name:34s} {duration:5.1f}s  {size / 1024:5.0f} KiB")
            except Exception as exc:
                print(f"  {name:34s} FAILED: {exc}", file=sys.stderr)
                failures.append(name)

    print("\nEVA ALERTS")
    for alert, text in VOICE_LINES.items():
        name = f"{alert}.ogg"
        try:
            duration, size = render_voice(text, EVA, VOICE_OUT / name)
            total_bytes += size
            total_seconds += duration
            print(f"  {name:34s} {duration:5.1f}s  {size / 1024:5.0f} KiB  \"{text}\"")
        except Exception as exc:
            print(f"  {name:34s} FAILED: {exc}", file=sys.stderr)
            failures.append(name)

    print(
        f"\n{21 + len(VOICE_LINES)} lines, {total_seconds / 60.0:.1f} minutes, "
        f"{total_bytes / (1024 * 1024):.2f} MiB Ogg"
    )
    if failures:
        print("FAILED: " + ", ".join(sorted(set(failures))), file=sys.stderr)
        return 1
    print("voice generation complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
