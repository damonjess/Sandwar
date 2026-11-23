#!/usr/bin/env python3
"""Generate Sandwar's retro RTS sound effects as local 22.05 kHz mono WAVs.

The primary path uses NumPy for layered noise, sweeps and saturation. If NumPy
is unavailable -- or SANDWAR_SFX_PURE_PYTHON=1 is set -- the same filenames are
rendered by a self-contained pure-Python fallback.

Output: assets/sfx/*.wav
"""

from __future__ import annotations

import math
import os
import random
import struct
import sys
import wave
from pathlib import Path

try:
    import numpy as np
except Exception:
    np = None

RATE = 22050
OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "sfx"

# name -> (recipe, variation)
SPECS = {
    "cannon_01.wav": ("cannon", 0),
    "cannon_02.wav": ("cannon", 1),
    "rocket_launch_01.wav": ("rocket_launch", 0),
    "rocket_launch_02.wav": ("rocket_launch", 1),
    "rifle_01.wav": ("rifle", 0),
    "rifle_02.wav": ("rifle", 1),
    "mg_burst.wav": ("mg_burst", 0),
    "explosion_small_01.wav": ("explosion_small", 0),
    "explosion_small_02.wav": ("explosion_small", 1),
    "explosion_medium_01.wav": ("explosion_medium", 0),
    "explosion_medium_02.wav": ("explosion_medium", 1),
    "explosion_building.wav": ("explosion_building", 0),
    "build_place.wav": ("build_place", 0),
    "ui_click.wav": ("ui_click", 0),
    "build_ready.wav": ("build_ready", 0),
    "low_power.wav": ("low_power", 0),
    "worm_roar.wav": ("worm_roar", 0),
}

DURATIONS = {
    "cannon": 0.62,
    "rocket_launch": 0.55,
    "rifle": 0.12,
    "mg_burst": 0.26,
    "explosion_small": 0.40,
    "explosion_medium": 0.82,
    "explosion_building": 1.38,
    "build_place": 0.42,
    "ui_click": 0.08,
    "build_ready": 0.56,
    "low_power": 1.05,
    "worm_roar": 2.60,
}

PEAKS = {
    "cannon": 0.88,
    "rocket_launch": 0.80,
    "rifle": 0.76,
    "mg_burst": 0.72,
    "explosion_small": 0.90,
    "explosion_medium": 0.92,
    "explosion_building": 0.94,
    "build_place": 0.86,
    "ui_click": 0.62,
    "build_ready": 0.72,
    "low_power": 0.70,
    "worm_roar": 0.95,
}


def seed_for(name: str, variation: int) -> int:
    return (sum((i + 1) * ord(c) for i, c in enumerate(name)) * 97 + variation * 7919) & 0x7FFFFFFF


# --------------------------------------------------------------------- NumPy path

def _np_rng(seed: int):
    return np.random.default_rng(seed)


def _np_t(duration: float):
    return np.arange(max(1, int(duration * RATE)), dtype=np.float64) / RATE


def _np_noise(n: int, rng) -> np.ndarray:
    return rng.standard_normal(n).astype(np.float64)


def _np_lowpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    a = 1.0 - math.exp(-2.0 * math.pi * max(cutoff, 10.0) / RATE)
    y = np.empty_like(x)
    state = 0.0
    for i in range(x.size):
        state += a * (x[i] - state)
        y[i] = state
    return y


def _np_highpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    return x - _np_lowpass(x, cutoff)


def _np_bandpass(x: np.ndarray, low: float, high: float) -> np.ndarray:
    return _np_lowpass(_np_highpass(x, low), high)


def _np_sweep(t: np.ndarray, start: float, end: float, duration: float) -> np.ndarray:
    k = np.clip(t / max(duration, 1.0e-5), 0.0, 1.0)
    return start + (end - start) * k


def _np_phase(freq: np.ndarray) -> np.ndarray:
    return 2.0 * math.pi * np.cumsum(freq) / RATE


def _np_env(t: np.ndarray, attack: float, decay: float) -> np.ndarray:
    a = np.clip(t / max(attack, 1.0e-5), 0.0, 1.0)
    return a * np.exp(-np.maximum(t - attack, 0.0) / max(decay, 1.0e-5))


def _np_soft(x: np.ndarray, drive: float = 1.2) -> np.ndarray:
    return np.tanh(x * drive) / math.tanh(drive)


def _np_grit(n: int, rng, amount: float = 0.018) -> np.ndarray:
    # The top octave of the 22 kHz sample rate: dry, slightly hissy texture.
    return _np_highpass(_np_noise(n, rng), 4800.0) * amount


def _np_finish(x: np.ndarray, peak_target: float) -> np.ndarray:
    x = np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0)
    x -= float(np.mean(x))
    n = x.size
    fade = min(int(0.008 * RATE), n // 4)
    if fade > 0:
        ramp = np.linspace(0.0, 1.0, fade, dtype=np.float64)
        x[:fade] *= ramp
        x[-fade:] *= ramp[::-1]
    peak = float(np.max(np.abs(x))) if n else 0.0
    if peak < 1.0e-8:
        x[-1] = 0.01
        peak = 0.01
    x *= peak_target / peak
    return np.clip(x, -1.0, 1.0)


def _np_cannon(variation: int) -> np.ndarray:
    rng = _np_rng(seed_for("cannon", variation))
    t = _np_t(DURATIONS["cannon"] + variation * 0.015)
    n = t.size
    freq = _np_sweep(t, 160.0 + variation * 4.0, 38.0 - variation * 1.5, 0.12)
    phase = _np_phase(freq)
    sub = np.sin(phase) * np.exp(-t / 0.22)
    harmonic = np.sin(phase * 2.0 + 0.7) * np.exp(-t / 0.10) * 0.22
    noise = _np_noise(n, rng)
    blast = _np_bandpass(noise, 250.0, 3150.0) * np.exp(-t / (0.042 + variation * 0.008))
    crunch = _np_highpass(noise, 2300.0) * np.exp(-t / 0.010)
    rumble = _np_lowpass(_np_noise(n, rng), 85.0) * np.exp(-t / 0.30)
    transient = np.sin(_np_phase(_np_sweep(t, 720.0, 160.0, 0.035))) * np.exp(-t / 0.012) * 0.35
    mix = sub * 0.95 + harmonic + blast * 0.52 + crunch * 0.40 + rumble * 0.72 + transient
    mix += _np_grit(n, rng, 0.022)
    mix = _np_soft(mix * (1.55 + variation * 0.10), 1.35)
    return _np_finish(mix, PEAKS["cannon"])


def _np_rocket_launch(variation: int) -> np.ndarray:
    rng = _np_rng(seed_for("rocket_launch", variation))
    t = _np_t(DURATIONS["rocket_launch"] + variation * 0.02)
    n = t.size
    noise = _np_noise(n, rng)
    ignition = _np_highpass(noise, 900.0) * np.exp(-t / 0.014) * 0.85
    ignition += np.sin(_np_phase(_np_sweep(t, 150.0, 62.0, 0.10))) * np.exp(-t / 0.045) * 0.55
    low_band = _np_bandpass(noise, 350.0, 1150.0) * np.clip(1.0 - t / 0.30, 0.0, 1.0)
    high_band = _np_bandpass(_np_noise(n, rng), 1200.0, 4400.0) * np.clip(t / 0.28, 0.0, 1.0)
    whoosh_env = np.clip(t / 0.025, 0.0, 1.0) * (1.0 - np.clip((t - 0.34) / 0.18, 0.0, 1.0))
    sputter = 0.86 + 0.12 * np.sin(2.0 * math.pi * (27.0 + variation * 3.0) * t)
    sputter += 0.06 * np.sin(2.0 * math.pi * 61.0 * t + 1.1)
    whoosh = (low_band * 0.72 + high_band * 0.58) * whoosh_env * sputter
    sweep_tone = np.sin(_np_phase(_np_sweep(t, 480.0 + variation * 60.0, 2100.0, 0.30)))
    sweep_tone *= np.exp(-t / 0.24) * 0.13
    mix = ignition + whoosh * 0.75 + sweep_tone
    mix += _np_grit(n, rng, 0.014)
    mix = _np_soft(mix * 1.20, 1.15)
    return _np_finish(mix, PEAKS["rocket_launch"])


def _np_rifle(variation: int) -> np.ndarray:
    rng = _np_rng(seed_for("rifle", variation))
    t = _np_t(DURATIONS["rifle"])
    n = t.size
    noise = _np_noise(n, rng)
    crack = _np_bandpass(noise, 1500.0 + variation * 180.0, 6200.0) * np.exp(-t / 0.008)
    punch_freq = 800.0 + variation * 42.0
    punch = np.sin(2.0 * math.pi * punch_freq * t) * np.exp(-t / 0.024) * 0.65
    mid = _np_bandpass(noise, 500.0, 2900.0) * np.exp(-t / 0.030) * 0.32
    tail = _np_bandpass(_np_noise(n, rng), 350.0, 1800.0) * np.exp(-t / 0.060) * 0.12
    mix = crack * 0.72 + punch + mid + tail
    mix += _np_grit(n, rng, 0.016)
    mix = _np_soft(mix * 1.35, 1.25)
    return _np_finish(mix, PEAKS["rifle"])


def _np_mg_burst() -> np.ndarray:
    rng = _np_rng(seed_for("mg_burst", 0))
    t = _np_t(DURATIONS["mg_burst"] + 0.04)
    n = t.size
    mix = np.zeros(n, dtype=np.float64)
    for shot in range(4):
        start = int((0.018 + shot * 0.047) * RATE)
        if start >= n:
            continue
        local = t[: n - start]
        noise = _np_noise(local.size, rng)
        crack = _np_bandpass(noise, 1700.0, 6800.0) * np.exp(-local / 0.007)
        punch = np.sin(2.0 * math.pi * (760.0 + shot * 22.0) * local) * np.exp(-local / 0.021) * 0.55
        mid = _np_bandpass(noise, 650.0, 2500.0) * np.exp(-local / 0.026) * 0.26
        mix[start:] += (crack * 0.60 + punch + mid)
    mix += _np_grit(n, rng, 0.012)
    mix = _np_soft(mix * 1.40, 1.2)
    return _np_finish(mix, PEAKS["mg_burst"])


def _np_explosion_small(variation: int) -> np.ndarray:
    rng = _np_rng(seed_for("explosion_small", variation))
    t = _np_t(DURATIONS["explosion_small"] + variation * 0.02)
    n = t.size
    noise = _np_noise(n, rng)
    phase = _np_phase(_np_sweep(t, 72.0 + variation * 5.0, 30.0, 0.16))
    sub = np.sin(phase) * np.exp(-t / 0.15)
    body = _np_lowpass(_np_noise(n, rng), 850.0) * np.exp(-t / 0.105) * 1.1
    crack = _np_bandpass(noise, 1400.0, 6200.0) * np.exp(-t / 0.018) * 0.75
    debris = _np_bandpass(_np_noise(n, rng), 220.0, 950.0) * np.exp(-t / 0.19) * 0.45
    mix = sub * 0.85 + body + crack + debris
    mix += _np_grit(n, rng, 0.020)
    mix = _np_soft(mix * 1.75, 1.4)
    return _np_finish(mix, PEAKS["explosion_small"])


def _np_explosion_medium(variation: int) -> np.ndarray:
    rng = _np_rng(seed_for("explosion_medium", variation))
    t = _np_t(DURATIONS["explosion_medium"] + variation * 0.03)
    n = t.size
    noise = _np_noise(n, rng)
    phase = _np_phase(_np_sweep(t, 90.0 + variation * 4.0, 25.0, 0.55))
    sub = np.sin(phase) * np.exp(-t / 0.40)
    low = _np_lowpass(_np_noise(n, rng), 420.0) * np.exp(-t / 0.30)
    roar = _np_bandpass(_np_noise(n, rng), 160.0, 1400.0) * np.exp(-t / 0.24) * 0.85
    crack = _np_bandpass(noise, 1000.0, 5200.0) * np.exp(-t / 0.020) * 0.68
    mix = sub * 1.05 + low * 1.35 + roar + crack
    mix += _np_grit(n, rng, 0.018)
    mix = _np_soft(mix * 1.85, 1.55)
    return _np_finish(mix, PEAKS["explosion_medium"])


def _np_explosion_building() -> np.ndarray:
    rng = _np_rng(seed_for("explosion_building", 0))
    t = _np_t(DURATIONS["explosion_building"])
    n = t.size
    noise = _np_noise(n, rng)
    phase = _np_phase(_np_sweep(t, 58.0, 20.0, 0.90))
    sub = np.sin(phase) * np.exp(-t / 0.62)
    rumble = _np_lowpass(_np_noise(n, rng), 140.0) * np.exp(-t / 0.62) * 1.65
    roller = np.sin(2.0 * math.pi * 3.1 * t + 0.8) * 0.35 + 1.0
    debris = _np_bandpass(_np_noise(n, rng), 220.0, 1600.0) * np.exp(-t / 0.55) * roller * 0.42
    mix = sub * 0.9 + rumble + debris
    for hit in (0.015, 0.16, 0.32, 0.49, 0.70, 0.94):
        start = int(hit * RATE)
        if start >= n:
            continue
        local = t[: n - start]
        hit_noise = _np_noise(local.size, rng)
        pop = _np_bandpass(hit_noise, 250.0, 2400.0) * np.exp(-local / 0.030) * 0.70
        metal = np.sin(2.0 * math.pi * (330.0 + hit * 420.0) * local) * np.exp(-local / 0.055) * 0.30
        mix[start:] += pop + metal
    mix += _np_grit(n, rng, 0.025)
    mix = _np_soft(mix * 1.70, 1.6)
    return _np_finish(mix, PEAKS["explosion_building"])


def _np_build_place() -> np.ndarray:
    rng = _np_rng(seed_for("build_place", 0))
    t = _np_t(DURATIONS["build_place"])
    n = t.size
    thud = np.sin(_np_phase(_np_sweep(t, 86.0, 29.0, 0.20))) * np.exp(-t / 0.16)
    concrete = _np_lowpass(_np_noise(n, rng), 480.0) * np.exp(-t / 0.095) * 1.25
    hiss = _np_bandpass(_np_noise(n, rng), 260.0, 1800.0) * np.exp(-t / 0.12) * 0.28
    mix = thud * 0.95 + concrete + hiss
    for hit, strength in ((0.10, 0.65), (0.205, 0.45)):
        start = int(hit * RATE)
        if start >= n:
            continue
        local = t[: n - start]
        clank_noise = _np_noise(local.size, rng)
        clank = _np_bandpass(clank_noise, 1200.0, 4700.0) * np.exp(-local / 0.020) * strength
        clank += np.sin(2.0 * math.pi * (410.0 + hit * 500.0) * local) * np.exp(-local / 0.035) * strength * 0.35
        mix[start:] += clank
    mix += _np_grit(n, rng, 0.018)
    mix = _np_soft(mix * 1.5, 1.35)
    return _np_finish(mix, PEAKS["build_place"])


def _np_ui_click() -> np.ndarray:
    rng = _np_rng(seed_for("ui_click", 0))
    t = _np_t(DURATIONS["ui_click"])
    n = t.size
    noise = _np_noise(n, rng)
    click = _np_bandpass(noise, 1900.0, 7600.0) * np.exp(-t / 0.005)
    metal = np.sin(2.0 * math.pi * 2650.0 * t) * np.exp(-t / 0.012) * 0.55
    lower = np.sin(2.0 * math.pi * 720.0 * t) * np.exp(-t / 0.018) * 0.28
    mix = click * 0.75 + metal + lower
    mix += _np_grit(n, rng, 0.010)
    mix = _np_soft(mix * 1.20, 1.1)
    return _np_finish(mix, PEAKS["ui_click"])


def _np_build_ready() -> np.ndarray:
    rng = _np_rng(seed_for("build_ready", 0))
    t = _np_t(DURATIONS["build_ready"])
    n = t.size
    env = np.clip(t / 0.008, 0.0, 1.0) * np.exp(-t / 0.24)
    vib = 1.0 + 0.006 * np.sin(2.0 * math.pi * 5.0 * t)
    tone = np.sin(2.0 * math.pi * 660.0 * vib * t) * 0.50
    tone += np.sin(2.0 * math.pi * 990.0 * t) * 0.38
    tone += np.sin(2.0 * math.pi * 1320.0 * t) * 0.18
    tone *= env
    click = _np_bandpass(_np_noise(n, rng), 1800.0, 5400.0) * np.exp(-t / 0.010) * 0.35
    mix = tone + click
    mix += _np_grit(n, rng, 0.010)
    mix = _np_soft(mix * 1.25, 1.2)
    return _np_finish(mix, PEAKS["build_ready"])


def _np_low_power() -> np.ndarray:
    rng = _np_rng(seed_for("low_power", 0))
    t = _np_t(DURATIONS["low_power"])
    n = t.size
    env = np.clip(t / 0.12, 0.0, 1.0) * np.clip((1.05 - t) / 0.20, 0.0, 1.0)
    hum = np.sin(2.0 * math.pi * 110.0 * t) * 0.28
    hum += np.sin(2.0 * math.pi * 165.0 * t + 0.6) * 0.16
    hum += np.sin(2.0 * math.pi * 220.0 * t) * 0.08
    tremolo = 0.72 + 0.28 * np.sin(2.0 * math.pi * 1.7 * t)
    beep = np.sin(2.0 * math.pi * 440.0 * t) * np.exp(-np.maximum(t - 0.10, 0.0) / 0.12)
    beep *= (t >= 0.10).astype(np.float64) * 0.22
    mix = (hum * tremolo + beep) * env
    mix += _np_grit(n, rng, 0.009)
    mix = _np_soft(mix * 1.15, 1.1)
    return _np_finish(mix, PEAKS["low_power"])


def _np_worm_roar() -> np.ndarray:
    rng = _np_rng(seed_for("worm_roar", 0))
    t = _np_t(DURATIONS["worm_roar"])
    n = t.size
    # Seismic sub-bass with a slow downward sweep and a throaty growl AM.
    f = 46.0 - 16.0 * np.clip(t / 1.9, 0.0, 1.0)
    phase = 2.0 * math.pi * np.cumsum(f) / RATE
    sub = np.sin(phase) * 0.85
    sub += np.sin(phase * 1.5 + 0.4) * 0.30
    sub += np.sin(phase * 2.0 + 1.1) * 0.18
    growl = 0.68 + 0.32 * np.sin(2.0 * math.pi * 7.5 * t + 0.6 * np.sin(2.0 * math.pi * 1.3 * t))
    # Sand hiss washing out with the shockwave.
    sand = _np_bandpass(_np_noise(n, rng), 180.0, 2600.0)
    wash = np.clip(t / 0.22, 0.0, 1.0) * np.clip((DURATIONS["worm_roar"] - t) / 1.2, 0.0, 1.0)
    # A wet maw snap as the teeth break the surface.
    snap_t = np.maximum(t - 0.55, 0.0)
    snap = _np_bandpass(_np_noise(n, rng), 900.0, 5200.0) * np.exp(-snap_t / 0.09) * (t >= 0.55)
    mix = (sub * growl + sand * 0.32 * wash + snap * 0.28) * np.clip(t / 0.10, 0.0, 1.0)
    mix = _np_soft(mix * 1.5, 1.35)
    return _np_finish(mix, PEAKS["worm_roar"])


def render_np(kind: str, variation: int) -> np.ndarray:
    return {
        "cannon": _np_cannon,
        "rocket_launch": _np_rocket_launch,
        "rifle": _np_rifle,
        "mg_burst": lambda _v: _np_mg_burst(),
        "explosion_small": _np_explosion_small,
        "explosion_medium": _np_explosion_medium,
        "explosion_building": lambda _v: _np_explosion_building(),
        "build_place": lambda _v: _np_build_place(),
        "ui_click": lambda _v: _np_ui_click(),
        "build_ready": lambda _v: _np_build_ready(),
        "low_power": lambda _v: _np_low_power(),
        "worm_roar": lambda _v: _np_worm_roar(),
    }[kind](variation)


# --------------------------------------------------------------- pure fallback

def _py_tanh(x: float, drive: float = 1.2) -> float:
    d = math.tanh(drive)
    return math.tanh(x * drive) / d if d else 0.0


def _py_finish(values: list[float], peak_target: float) -> list[float]:
    n = len(values)
    if not n:
        return [0.01]
    dc = sum(values) / n
    values = [v - dc for v in values]
    fade = min(int(0.008 * RATE), n // 4)
    for i in range(fade):
        k = i / max(fade - 1, 1)
        values[i] *= k
        values[-1 - i] *= k
    peak = max(max(abs(v) for v in values), 1.0e-8)
    gain = peak_target / peak
    return [max(-1.0, min(1.0, v * gain)) for v in values]


def render_py(kind: str, variation: int) -> list[float]:
    name = f"{kind}_{variation}"
    rng = random.Random(seed_for(name, variation))
    duration = DURATIONS[kind] + (0.02 if variation else 0.0)
    n = max(1, int(duration * RATE))
    out: list[float] = []
    lp = 0.0
    lp2 = 0.0
    hp_prev = 0.0
    low_state = 0.0
    phase = 0.0
    for i in range(n):
        t = i / RATE
        white = rng.uniform(-1.0, 1.0)
        lp += 0.12 * (white - lp)
        lp2 += 0.035 * (lp - lp2)
        hp = white - lp
        grit = (rng.uniform(-1.0, 1.0) - lp) * 0.018
        v = 0.0
        if kind == "cannon":
            f = 160.0 + (38.0 - 160.0) * min(t / 0.12, 1.0)
            phase += 2.0 * math.pi * f / RATE
            env = math.exp(-t / 0.22)
            v = math.sin(phase) * env * 0.95
            v += math.sin(phase * 2.0 + 0.7) * math.exp(-t / 0.10) * 0.22
            v += (lp * 2.0 + white * math.exp(-t / 0.01)) * math.exp(-t / 0.07) * 0.65
            v += lp2 * math.exp(-t / 0.30) * 1.1
            v = _py_tanh(v * 1.55, 1.35)
        elif kind == "rocket_launch":
            f = 150.0 + (62.0 - 150.0) * min(t / 0.10, 1.0)
            phase += 2.0 * math.pi * f / RATE
            ignition = math.sin(phase) * math.exp(-t / 0.045) * 0.5
            ignition += white * math.exp(-t / 0.014) * 0.75
            whoosh = (lp * 1.4 + hp * 0.45) * max(0.0, 1.0 - t / 0.42)
            whoosh *= max(0.0, min(1.0, t / 0.025))
            sputter = 0.86 + 0.12 * math.sin(2.0 * math.pi * 27.0 * t)
            v = _py_tanh((ignition + whoosh * sputter) * 1.2, 1.15)
        elif kind == "rifle":
            v = (white * math.exp(-t / 0.008) * 0.72)
            v += (lp * 1.7 + hp * 0.35) * math.exp(-t / 0.030) * 0.55
            v += math.sin(2.0 * math.pi * 800.0 * t) * math.exp(-t / 0.024) * 0.55
            v = _py_tanh(v * 1.35, 1.25)
        elif kind == "mg_burst":
            local = (t - 0.018) % 0.047
            shot = int(max(0.0, t - 0.018) / 0.047)
            gate = 1.0 if t < 0.22 else 0.0
            v = (white * math.exp(-local / 0.007) * 0.65
                 + math.sin(2.0 * math.pi * (760.0 + shot * 22.0) * local) * math.exp(-local / 0.021) * 0.5
                 + lp * math.exp(-local / 0.026) * 0.45) * gate
            v = _py_tanh(v * 1.4, 1.2)
        elif kind in ("explosion_small", "explosion_medium", "explosion_building"):
            deep_end = 30.0 if kind == "explosion_small" else 25.0
            sweep_time = 0.16 if kind == "explosion_small" else 0.55
            f = 90.0 + (deep_end - 90.0) * min(t / sweep_time, 1.0)
            phase += 2.0 * math.pi * f / RATE
            decay = 0.15 if kind == "explosion_small" else (0.30 if kind == "explosion_medium" else 0.62)
            v = math.sin(phase) * math.exp(-t / decay) * (0.9 if kind != "explosion_small" else 0.8)
            v += lp2 * math.exp(-t / (0.10 if kind == "explosion_small" else 0.30)) * (1.8 if kind != "explosion_small" else 1.0)
            v += white * math.exp(-t / 0.018) * 0.65
            if kind == "explosion_building":
                v += lp * math.exp(-t / 0.55) * 1.5
                for hit in (0.16, 0.32, 0.49, 0.70, 0.94):
                    local = t - hit
                    if local >= 0.0:
                        v += white * math.exp(-local / 0.030) * 0.45
                        v += math.sin(2.0 * math.pi * (330.0 + hit * 420.0) * local) * math.exp(-local / 0.055) * 0.2
            v = _py_tanh(v * (1.75 if kind != "explosion_small" else 1.5), 1.5)
        elif kind == "build_place":
            f = 86.0 + (29.0 - 86.0) * min(t / 0.20, 1.0)
            phase += 2.0 * math.pi * f / RATE
            v = math.sin(phase) * math.exp(-t / 0.16) * 0.9
            v += lp2 * math.exp(-t / 0.10) * 1.5
            for hit in (0.10, 0.205):
                local = t - hit
                if local >= 0.0:
                    v += hp * math.exp(-local / 0.020) * 0.5
                    v += math.sin(2.0 * math.pi * 410.0 * local) * math.exp(-local / 0.035) * 0.2
            v = _py_tanh(v * 1.5, 1.35)
        elif kind == "ui_click":
            v = white * math.exp(-t / 0.006) * 0.65
            v += math.sin(2.0 * math.pi * 2650.0 * t) * math.exp(-t / 0.012) * 0.5
            v += math.sin(2.0 * math.pi * 720.0 * t) * math.exp(-t / 0.018) * 0.2
            v = _py_tanh(v * 1.2, 1.1)
        elif kind == "build_ready":
            env = max(0.0, min(1.0, t / 0.008)) * math.exp(-t / 0.24)
            v = (math.sin(2.0 * math.pi * 660.0 * t) * 0.5
                 + math.sin(2.0 * math.pi * 990.0 * t) * 0.38
                 + math.sin(2.0 * math.pi * 1320.0 * t) * 0.18) * env
            v += white * math.exp(-t / 0.010) * 0.25
            v = _py_tanh(v * 1.25, 1.2)
        elif kind == "worm_roar":
            f = 46.0 - 16.0 * min(t / 1.9, 1.0)
            phase += 2.0 * math.pi * f / RATE
            growl = 0.68 + 0.32 * math.sin(2.0 * math.pi * 7.5 * t + 0.6 * math.sin(2.0 * math.pi * 1.3 * t))
            wash = max(0.0, min(1.0, t / 0.22)) * max(0.0, min(1.0, (DURATIONS["worm_roar"] - t) / 1.2))
            v = (math.sin(phase) * 0.85
                 + math.sin(phase * 1.5 + 0.4) * 0.30
                 + math.sin(phase * 2.0 + 1.1) * 0.18) * growl
            v += lp * wash * 0.5
            if t >= 0.55:
                v += hp * math.exp(-(t - 0.55) / 0.09) * 0.30
            v *= max(0.0, min(1.0, t / 0.10))
            v = _py_tanh(v * 1.5, 1.35)
        elif kind == "low_power":
            env = max(0.0, min(1.0, t / 0.12)) * max(0.0, min(1.0, (1.05 - t) / 0.20))
            tremolo = 0.72 + 0.28 * math.sin(2.0 * math.pi * 1.7 * t)
            v = (math.sin(2.0 * math.pi * 110.0 * t) * 0.28
                 + math.sin(2.0 * math.pi * 165.0 * t + 0.6) * 0.16
                 + math.sin(2.0 * math.pi * 220.0 * t) * 0.08) * tremolo
            if t >= 0.10:
                v += math.sin(2.0 * math.pi * 440.0 * t) * math.exp(-(t - 0.10) / 0.12) * 0.22
            v *= env
            v = _py_tanh(v * 1.15, 1.1)
        out.append(v + grit)
    return _py_finish(out, PEAKS[kind])


# --------------------------------------------------------------------- output

def write_wav(path: Path, samples) -> tuple[float, float]:
    if np is not None and not isinstance(samples, list):
        values = np.asarray(samples, dtype=np.float64)
        peak = float(np.max(np.abs(values)))
        rms = float(np.sqrt(np.mean(values * values)))
        pcm = np.clip(values, -1.0, 1.0) * 32767.0
        frames = pcm.astype("<i2").tobytes()
    else:
        values = list(samples)
        peak = max(abs(v) for v in values)
        rms = math.sqrt(sum(v * v for v in values) / max(len(values), 1))
        frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32767.0)) for v in values)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(frames)
    return peak, rms


def main() -> int:
    force_pure = os.environ.get("SANDWAR_SFX_PURE_PYTHON") == "1"
    use_numpy = np is not None and not force_pure
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Sandwar SFX generator: {RATE} Hz, mono, 16-bit")
    print(f"engine: {'NumPy ' + np.__version__ if use_numpy else 'pure Python'}")
    print(f"output: {OUT_DIR}")
    failures = []
    for filename, (kind, variation) in SPECS.items():
        values = render_np(kind, variation) if use_numpy else render_py(kind, variation)
        path = OUT_DIR / filename
        peak, rms = write_wav(path, values)
        duration = len(values) / RATE
        print(f"  {filename:28s} {duration:5.2f}s  peak={peak:5.2f}  rms={rms:5.3f}")
        if peak < 0.05 or rms < 0.002:
            failures.append(filename)
    generated = sorted(p.name for p in OUT_DIR.glob("*.wav"))
    missing = sorted(set(SPECS) - set(generated))
    if missing:
        failures.extend(missing)
    if failures:
        print("FAILED / silent: " + ", ".join(sorted(set(failures))), file=sys.stderr)
        return 1
    print(f"OK: generated {len(SPECS)} non-silent WAV files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
