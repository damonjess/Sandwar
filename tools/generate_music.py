#!/usr/bin/env python3
"""Generate Sandwar's three seamless Dune 2000-style music loops.

Pipeline:
    mido (compose MIDI) -> fluidsynth (FluidR3_GM soundfont) -> ffmpeg (Ogg Vorbis)

The tracks use a D Hijaz / Phrygian-dominant centre, deep synth bass, brooding
GM pads and a mix of ethnic and industrial percussion. Every track is composed
to an exact bar boundary; the rendered release tail is folded back into the
loop start and crossfaded so Ogg playback repeats without a click or a gap.

Output:
    assets/music/menu_arrakis.ogg      (18 bars @ 72 BPM  = 60.0 s)
    assets/music/desert_ambient.ogg    (24 bars @ 88 BPM  = 65.5 s)
    assets/music/battle_combat.ogg     (32 bars @ 126 BPM = 61.0 s)
"""

from __future__ import annotations

import math
import random
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

try:
    import mido
    import numpy as np
except Exception as exc:  # pragma: no cover - target machine has both
    print(f"generate_music: missing dependency: {exc}", file=sys.stderr)
    print("  install with: .tools-venv/bin/pip install mido numpy", file=sys.stderr)
    raise SystemExit(1)

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "music"
SOUNDFONT = Path("/usr/share/sounds/sf2/FluidR3_GM.sf2")
TPB = 480
BEATS_PER_BAR = 4

# D Hijaz / Phrygian dominant. The augmented second (Eb -> F#) gives the
# unmistakable desert scale while the b7 keeps the harmony dark.
SCALE = [0, 1, 4, 5, 7, 8, 10]


def degree(root: int, step: int, octave: int = 0) -> int:
    """Map a scale degree (can exceed one octave) to a MIDI note."""
    octave += step // 7
    return int(root + SCALE[step % 7] + 12 * octave)


class Song:
    """Small absolute-time MIDI builder with one track per channel."""

    def __init__(self, name: str, bpm: float, bars: int):
        self.name = name
        self.bpm = float(bpm)
        self.bars = int(bars)
        self.total_beats = self.bars * BEATS_PER_BAR
        self.events: dict[int, list[tuple[int, mido.Message]]] = {}
        self.names: dict[int, str] = {}

    def channel(self, ch: int, program: int, name: str, volume: int = 94,
                pan: int = 64, reverb: int = 76, chorus: int = 18) -> None:
        if ch in self.events:
            raise ValueError(f"channel {ch} already used")
        self.events[ch] = []
        self.names[ch] = name
        if ch != 9:
            self._add(ch, 0, mido.Message("program_change", channel=ch, program=program))
        self._add(ch, 0, mido.Message("control_change", channel=ch, control=7, value=volume))
        self._add(ch, 0, mido.Message("control_change", channel=ch, control=10, value=pan))
        self._add(ch, 0, mido.Message("control_change", channel=ch, control=91, value=reverb))
        self._add(ch, 0, mido.Message("control_change", channel=ch, control=93, value=chorus))

    def _add(self, ch: int, tick: int, msg: mido.Message) -> None:
        self.events[ch].append((max(0, int(tick)), msg))

    def note(self, ch: int, pitch: int, beat: float, duration: float,
             velocity: int = 90) -> None:
        if pitch < 0 or pitch > 127 or duration <= 0:
            return
        start = int(round(beat * TPB))
        end = int(round((beat + duration) * TPB)) - 1
        if end <= start:
            end = start + 1
        vel = max(1, min(127, int(velocity)))
        self._add(ch, start, mido.Message("note_on", channel=ch, note=int(pitch), velocity=vel))
        self._add(ch, end, mido.Message("note_on", channel=ch, note=int(pitch), velocity=0))

    def chord(self, ch: int, pitches: list[int], beat: float, duration: float,
              velocity: int = 80, spread: float = 0.0) -> None:
        for i, pitch in enumerate(pitches):
            self.note(ch, pitch, beat + spread * i, duration, velocity)

    def drum(self, beat: float, pitch: int, velocity: int = 90,
             duration: float = 0.12) -> None:
        self.note(9, pitch, beat, duration, velocity)

    def save(self, path: Path) -> None:
        mid = mido.MidiFile(type=1, ticks_per_beat=TPB)
        mid.tracks.append(self._meta_track())
        for ch in sorted(self.events):
            track = mido.MidiTrack()
            track.append(mido.MetaMessage("track_name", name=self.names.get(ch, f"ch{ch}"), time=0))
            last = 0
            for tick, msg in sorted(self.events[ch], key=lambda item: item[0]):
                track.append(msg.copy(time=max(0, tick - last)))
                last = tick
            # A marker/meta event at the exact loop end tells FluidSynth how long
            # the sequence is even when the final bar ends in silence.
            end_tick = self.total_beats * TPB
            track.append(mido.MetaMessage("marker", text="loop_end", time=max(0, end_tick - last)))
            mid.tracks.append(track)
        mid.save(str(path))

    def _meta_track(self) -> mido.MidiTrack:
        track = mido.MidiTrack()
        track.append(mido.MetaMessage("track_name", name=self.name, time=0))
        track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(self.bpm), time=0))
        track.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
        track.append(mido.MetaMessage("marker", text="loop_start", time=0))
        track.append(mido.MetaMessage("marker", text="loop_end", time=self.total_beats * TPB))
        return track


# ------------------------------------------------------------------ menu

def build_menu() -> Song:
    """Dark desert drone, slow ethnic percussion and a mournful lead."""
    song = Song("menu_arrakis", 72, 18)
    song.channel(0, 38, "Deep analog bass", volume=98, pan=64, reverb=52, chorus=8)
    song.channel(1, 89, "Warm desert pad", volume=72, pan=64, reverb=104, chorus=28)
    song.channel(2, 52, "Choir shadow", volume=54, pan=52, reverb=112, chorus=36)
    song.channel(3, 81, "Mysterious lead", volume=78, pan=70, reverb=96, chorus=22)
    song.channel(4, 95, "Slow sweep", volume=38, pan=46, reverb=118, chorus=20)
    song.channel(5, 85, "Voice lead echo", volume=46, pan=84, reverb=120, chorus=40)
    song.channel(6, 104, "Sitar pluck", volume=48, pan=38, reverb=92, chorus=26)
    song.channel(9, 0, "Ethnic percussion", volume=98, pan=64, reverb=58, chorus=0)

    # Two bars per chord; the final Eb -> D is a loop turnaround.
    chords = [
        ("D", [50, 54, 57, 64], 38, "D"),
        ("Eb", [51, 55, 58, 65], 39, "Eb"),
        ("D", [50, 54, 57, 64], 38, "D"),
        ("C", [48, 51, 55, 60], 36, "C"),
        ("Gm", [55, 58, 62, 67], 43, "G"),
        ("Bb", [46, 50, 53, 58], 34, "Bb"),
        ("Adim", [45, 48, 51, 57], 33, "A"),
        ("D", [50, 54, 57, 64], 38, "D"),
        ("Eb", [51, 55, 58, 65], 39, "Eb"),
    ]

    # A long, restrained modal melody. (degree, start beat, duration)
    melody = [
        [(4, 0.0, 3.5), (3, 4.0, 1.0), (2, 5.0, 2.5)],
        [(5, 0.0, 2.0), (4, 2.0, 1.5), (1, 4.0, 3.5)],
        [(4, 0.0, 4.0), (3, 4.0, 1.5), (0, 5.5, 2.0)],
        [(5, 0.0, 3.0), (4, 3.0, 1.0), (2, 4.0, 3.25)],
        [(2, 0.0, 2.0), (4, 2.0, 1.5), (5, 4.0, 2.0), (4, 6.0, 1.75)],
        [(3, 0.0, 4.0), (5, 4.0, 1.0), (6, 5.0, 2.5)],
        [(4, 0.0, 2.0), (5, 2.0, 2.0), (4, 4.0, 1.0), (3, 5.0, 2.5)],
        [(0, 0.0, 4.0), (1, 4.0, 1.5), (2, 5.5, 2.25)],
        [(4, 0.0, 3.0), (3, 3.0, 1.5), (0, 5.0, 2.75)],
    ]

    for seg, (label, voicing, bass_root, _) in enumerate(chords):
        start = seg * 8.0
        song.chord(1, voicing, start, 7.92, velocity=52, spread=0.035)
        # High choir shadow, deliberately sparse and breathy.
        song.chord(2, [v + 12 for v in voicing[-2:]], start + 0.08, 6.8, velocity=31, spread=0.12)
        # Deep sub pulse: root plus occasional fifth/octave.
        song.note(0, bass_root - 12, start, 3.6, 82)
        for offset, dur, vel in [
            (0.0, 0.85, 102), (1.5, 0.48, 70), (2.5, 0.9, 92),
            (3.75, 0.38, 62), (5.5, 0.72, 96), (6.5, 0.34, 68),
        ]:
            song.note(0, bass_root, start + offset, dur, vel)
        song.note(0, bass_root + 7, start + 5.5, 0.4, 54)
        # Slow evolving upper pad, with the same root so the drone never breaks.
        song.note(4, degree(74, seg % 7), start + 0.25, 7.4, 26)

        # Sparse sitar arpeggio around the chord.
        pluck_root = voicing[0] + 12
        for i, (offset, interval) in enumerate([(2.0, 0), (3.5, 7), (5.0, 12), (6.75, 15)]):
            song.note(6, pluck_root + interval, start + offset, 0.55, 42 + (i % 2) * 8)

        for degree_index, offset, duration in melody[seg]:
            pitch = degree(62, degree_index)
            song.note(3, pitch, start + offset, duration, 82)
            # Soft delayed answer in the other speaker.
            song.note(5, pitch - 12, start + offset + 0.75, duration * 0.82, 38)

        # Desert frame drums: breathy shaker, deep taiko, low tom answer.
        song.drum(start + 0.0, 47, 94)
        song.drum(start + 2.5, 45, 62)
        song.drum(start + 4.0, 47, 78)
        song.drum(start + 6.5, 41, 54)
        song.drum(start + 5.5, 75, 38)
        for step in range(16):
            beat = start + step * 0.5
            vel = 22 + (8 if step % 4 == 0 else 0)
            song.drum(beat, 82, vel, 0.06)
        if seg % 2 == 0:
            song.drum(start, 53, 42, 0.4)
        if seg in (4, 8):
            song.drum(start + 7.5, 55, 50, 0.6)

    return song


# ------------------------------------------------------------------ ambient

def build_ambient() -> Song:
    """Tense harvesting groove: pulsing sub, muted drums and sparse arps."""
    song = Song("desert_ambient", 88, 24)
    song.channel(0, 39, "Pulsing sub bass", volume=98, pan=64, reverb=36, chorus=6)
    song.channel(1, 89, "Brooding pad", volume=66, pan=64, reverb=100, chorus=26)
    song.channel(2, 82, "Sci-fi arpeggio", volume=60, pan=44, reverb=104, chorus=34)
    song.channel(3, 95, "Distant shimmer", volume=36, pan=78, reverb=120, chorus=18)
    song.channel(4, 108, "Kalimba echo", volume=44, pan=72, reverb=100, chorus=22)
    song.channel(5, 52, "Choir bed", volume=42, pan=58, reverb=112, chorus=34)
    song.channel(9, 0, "Harvest percussion", volume=98, pan=64, reverb=54, chorus=0)

    chords = [
        ("D", [50, 54, 57, 64], 38),
        ("Bb", [46, 50, 53, 58], 34),
        ("Gm", [55, 58, 62, 67], 43),
        ("Eb", [51, 55, 58, 65], 39),
        ("C", [48, 51, 55, 60], 36),
        ("D", [50, 54, 57, 64], 38),
    ]
    rng = random.Random(2000)

    for block, (label, voicing, bass_root) in enumerate(chords):
        start = block * 16.0
        song.chord(1, voicing, start, 15.9, velocity=48, spread=0.04)
        song.chord(5, [v + 12 for v in voicing[-2:]], start + 0.4, 14.5, velocity=27, spread=0.14)
        song.note(3, degree(86, block % 7, 1), start + 2.0, 12.0, 22)
        song.note(3, degree(86, (block + 3) % 7, 1), start + 9.0, 6.0, 18)

        for bar in range(4):
            b = start + bar * 4.0
            song.note(0, bass_root - 12, b, 1.8, 74)
            # A clipped eighth-note pulse: the engine of the harvesting groove.
            for offset, interval, dur, vel in [
                (0.0, 0, 0.42, 108), (0.75, 0, 0.28, 72),
                (1.5, 12, 0.34, 88), (2.0, 0, 0.40, 98),
                (2.75, 7, 0.28, 68), (3.25, 0, 0.34, 86),
                (3.75, 12, 0.24, 62),
            ]:
                song.note(0, bass_root + interval, b + offset, dur, vel)

            # Muted kick/snare pattern; the low tom and conga carry the desert
            # colour instead of a bright rock kit.
            song.drum(b + 0.0, 35, 102)
            song.drum(b + 2.5, 35, 86)
            song.drum(b + 1.5, 37, 54)
            song.drum(b + 3.5, 37, 50)
            song.drum(b + 2.0, 38, 56)
            song.drum(b + 3.0, 62, 40)
            song.drum(b + 0.5, 45, 34)
            for step in range(8):
                song.drum(b + step * 0.5, 42, 30 + (10 if step % 2 == 0 else 0), 0.06)
            for step in range(16):
                song.drum(b + step * 0.25, 82, 17 + (5 if step % 4 == 0 else 0), 0.04)
            if bar == 3:
                song.drum(b + 3.25, 41, 48)
                song.drum(b + 3.5, 43, 55)
                song.drum(b + 3.75, 45, 62)

        # Sparse 16th-note arpeggios over the first two bars of each block.
        arp_notes = [v + 12 for v in voicing] + [voicing[0] + 24]
        for bar in (0, 1):
            b = start + bar * 4.0
            for step in range(16):
                if rng.random() < 0.24:
                    continue
                pitch = arp_notes[(step * 2 + bar) % len(arp_notes)]
                beat = b + step * 0.25
                song.note(2, pitch, beat, 0.20, 48 + (10 if step % 4 == 0 else 0))
                if step % 4 == 0:
                    song.note(4, pitch - 12, beat + 0.125, 0.24, 28)

    return song


# ------------------------------------------------------------------ battle

def build_battle() -> Song:
    """Industrial combat: driving kit, urgent bass and distorted stabs."""
    song = Song("battle_combat", 126, 32)
    song.channel(0, 39, "Urgent bass", volume=104, pan=64, reverb=34, chorus=4)
    song.channel(1, 91, "War pad", volume=58, pan=64, reverb=92, chorus=24)
    song.channel(2, 81, "Combat lead", volume=78, pan=68, reverb=78, chorus=18)
    song.channel(3, 30, "Distorted guitar", volume=72, pan=48, reverb=56, chorus=10)
    song.channel(4, 62, "Brass stabs", volume=66, pan=78, reverb=62, chorus=14)
    song.channel(5, 87, "Bass lead double", volume=40, pan=42, reverb=76, chorus=28)
    song.channel(9, 0, "Industrial kit", volume=104, pan=64, reverb=48, chorus=0)

    # Four bars per chord; D minor/major colours around the Hijaz centre.
    progression = [
        ("D", [50, 54, 57, 62], 38, [0, 4, 7]),
        ("D", [50, 54, 57, 62], 38, [0, 4, 7]),
        ("Eb", [51, 55, 58, 63], 39, [0, 4, 7]),
        ("C", [48, 51, 55, 60], 36, [0, 3, 7]),
        ("Gm", [55, 58, 62, 67], 43, [0, 3, 7]),
        ("Bb", [46, 50, 53, 58], 34, [0, 4, 7]),
        ("Adim", [45, 48, 51, 57], 33, [0, 3, 6]),
        ("D", [50, 54, 57, 62], 38, [0, 4, 7]),
    ]

    lead_motif = [
        (4, 0.0, 0.45), (3, 0.5, 0.25), (4, 0.75, 0.5), (5, 1.5, 0.65),
        (4, 2.5, 0.4), (3, 3.0, 0.4), (2, 3.5, 0.4), (1, 4.0, 0.7),
        (0, 5.0, 0.5), (1, 5.5, 0.25), (2, 5.75, 0.5), (4, 6.5, 1.0),
    ]
    lead_motif_b = [
        (5, 0.0, 0.4), (4, 0.5, 0.4), (5, 1.0, 0.45), (6, 1.75, 0.5),
        (5, 2.5, 0.4), (4, 3.0, 0.35), (3, 3.5, 0.6), (2, 4.25, 0.5),
        (1, 5.0, 0.5), (2, 5.5, 0.35), (4, 6.0, 0.5), (3, 6.75, 0.75),
    ]

    for seg, (label, voicing, bass_root, triad) in enumerate(progression):
        start = seg * 16.0
        breakdown = seg == 4
        song.chord(1, voicing, start, 15.8, velocity=38 if breakdown else 46, spread=0.02)

        for bar in range(4):
            b = start + bar * 4.0
            quiet = breakdown and bar < 3
            # Bassline: relentless eighth/16th pulse with octave lifts.
            pattern = [
                (0.0, 0, 0.20, 114), (0.5, 0, 0.18, 82), (0.75, 12, 0.18, 98),
                (1.5, 0, 0.20, 104), (2.0, 0, 0.18, 88), (2.5, 7, 0.18, 96),
                (3.0, 0, 0.20, 108), (3.5, 12, 0.18, 94), (3.75, 0, 0.18, 76),
            ]
            for offset, interval, dur, vel in pattern:
                song.note(0, bass_root + interval, b + offset, dur,
                          56 if quiet else vel)
            if bar == 3 and not quiet:
                song.note(0, bass_root + 10, b + 3.75, 0.2, 72)

            # Kit: four-on-the-floor under a busy industrial top end.
            if not quiet:
                for offset in (0.0, 1.0, 2.0, 3.0):
                    song.drum(b + offset, 35, 112)
                if bar % 2 == 1:
                    song.drum(b + 2.75, 35, 78)
                for offset in (1.0, 3.0):
                    song.drum(b + offset, 38, 108)
                for step in range(16):
                    song.drum(b + step * 0.25, 42, 38 + (16 if step % 4 == 0 else 0), 0.045)
                for offset in (0.0, 1.5, 2.5, 3.5):
                    song.drum(b + offset, 51, 55, 0.12)
                for offset in (0.75, 1.75, 2.75, 3.75):
                    song.drum(b + offset, 56, 40, 0.09)
                if bar == 0 and seg % 2 == 0:
                    song.drum(b, 52, 92, 1.1)
                if bar == 3:
                    song.drum(b + 3.25, 45, 62)
                    song.drum(b + 3.5, 47, 74)
                    song.drum(b + 3.75, 41, 68)
            else:
                song.drum(b + 0.0, 35, 60)
                song.drum(b + 2.5, 47, 44)

            # Distorted power-chord stabs, tight and syncopated.
            if not quiet:
                power = [bass_root + 12, bass_root + 19, bass_root + 24]
                for offset, dur, vel in [(0.5, 0.16, 84), (1.75, 0.14, 70),
                                          (2.5, 0.18, 92), (3.25, 0.12, 66)]:
                    song.chord(3, power, b + offset, dur, velocity=vel)
                # Brass answers the guitar on the strong beats.
                brass = [50 + interval for interval in triad]
                song.chord(4, brass, b + 0.0, 0.22, velocity=78)
                song.chord(4, brass, b + 2.0, 0.18, velocity=64)

        # Lead enters after the eight-bar intro, drops out for the breakdown,
        # then returns for the final push.
        if 1 <= seg <= 3 or seg >= 5:
            phrase = lead_motif if seg % 2 == 0 else lead_motif_b
            for degree_index, offset, duration in phrase:
                pitch = degree(62, degree_index)
                song.note(2, pitch, start + offset, duration, 88)
                song.note(5, pitch - 12, start + offset + 0.25, duration * 0.8, 34)
            # A second answer in the back half of the four-bar phrase.
            for degree_index, offset, duration in phrase[:6]:
                song.note(2, degree(62, degree_index, 1), start + 8.0 + offset,
                          duration, 68)

        # Breakdown riser: tom roll into the returning wall of sound.
        if breakdown:
            for step in range(16):
                song.drum(start + 12.0 + step * 0.25, 41 + (step % 3),
                          42 + step * 4, 0.06)

    return song


# ------------------------------------------------------------------ render

def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())
    if width != 2:
        raise RuntimeError(f"{path.name}: expected 16-bit PCM")
    data = np.frombuffer(frames, dtype="<i2").astype(np.float64) / 32768.0
    if channels == 2:
        data = data.reshape(-1, 2)
    else:
        data = data.reshape(-1, 1)
    return data, rate


def write_wav(path: Path, data: np.ndarray, rate: int) -> None:
    values = np.clip(data, -1.0, 1.0)
    pcm = (values * 32767.0).astype("<i2").tobytes()
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(data.shape[1])
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(pcm)


def fold_loop(data: np.ndarray, expected: int, rate: int) -> np.ndarray:
    """Trim/pad to the exact bar length and seam the release tail into the start."""
    if data.shape[0] < expected:
        pad = np.zeros((expected - data.shape[0], data.shape[1]), dtype=np.float64)
        data = np.concatenate([data, pad], axis=0)
    body = data[:expected].copy()
    tail = data[expected:]
    # The renderer keeps playing release tails after the final bar. Put that
    # continuation at the start of the loop, then crossfade into the composed
    # opening so the waveform is continuous across the wrap point.
    cross = min(len(tail), int(0.22 * rate), expected // 2)
    if cross > 8:
        t = np.linspace(0.0, 1.0, cross, dtype=np.float64)[:, None]
        curve = t * t * (3.0 - 2.0 * t)
        body[:cross] = tail[:cross] * (1.0 - curve) + body[:cross] * curve
    # De-click the very edge without creating an audible gap.
    edge = min(int(0.004 * rate), expected // 4)
    if edge > 2:
        ramp = np.linspace(0.0, 1.0, edge, dtype=np.float64)[:, None]
        body[:edge] *= ramp
        body[-edge:] *= ramp[::-1]
    return body


def normalize_peak(data: np.ndarray, peak: float = 0.91) -> np.ndarray:
    top = float(np.max(np.abs(data))) if data.size else 0.0
    if top < 1e-8:
        return data
    return data / top * peak


def render(song: Song, seconds: float) -> tuple[Path, float]:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f"{song.name}.ogg"
    if not SOUNDFONT.exists():
        raise FileNotFoundError(f"FluidR3 soundfont not found at {SOUNDFONT}")
    fluidsynth = shutil.which("fluidsynth")
    ffmpeg = shutil.which("ffmpeg")
    if not fluidsynth or not ffmpeg:
        raise FileNotFoundError("fluidsynth and ffmpeg must be installed")

    with tempfile.TemporaryDirectory(prefix="sandwar_music_") as tmp:
        tmp_dir = Path(tmp)
        midi_path = tmp_dir / f"{song.name}.mid"
        raw_path = tmp_dir / f"{song.name}_raw.wav"
        loop_path = tmp_dir / f"{song.name}_loop.wav"
        song.save(midi_path)
        subprocess.run(
            [fluidsynth, "-ni", "-g", "0.72", "-F", str(raw_path),
             str(SOUNDFONT), str(midi_path)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        data, rate = read_wav(raw_path)
        expected = int(round(seconds * rate))
        looped = normalize_peak(fold_loop(data, expected, rate), 0.88)
        write_wav(loop_path, looped, rate)

        # One-pass EBU loudness normalisation plus the Ogg Vorbis encode. The
        # limiter is a safety net; the composition is already peak-normalised.
        subprocess.run(
            [ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
             "-i", str(loop_path),
             "-af", "loudnorm=I=-16:TP=-1.5:LRA=9,alimiter=limit=0.93",
             "-ar", str(rate), "-ac", "2", "-c:a", "libvorbis", "-q:a", "3",
             str(out_path)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )

    duration = probe_duration(out_path)
    size = out_path.stat().st_size
    print(f"  {out_path.name:24s} {duration:6.2f}s  {size / 1024:6.0f} KiB")
    return out_path, duration


def probe_duration(path: Path) -> float:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return 0.0
    result = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        check=True, capture_output=True, text=True,
    )
    return float(result.stdout.strip())


def main() -> int:
    tracks = [
        ("menu_arrakis", build_menu, 60.0),
        ("desert_ambient", build_ambient, 24 * 4 * 60.0 / 88.0),
        ("battle_combat", build_battle, 32 * 4 * 60.0 / 126.0),
    ]
    print("Sandwar procedural soundtrack")
    print(f"soundfont: {SOUNDFONT}")
    print(f"output:    {OUT_DIR}")
    failures: list[str] = []
    for name, builder, seconds in tracks:
        try:
            song = builder()
            path, duration = render(song, seconds)
            if not path.exists() or path.stat().st_size < 4096:
                failures.append(name)
            if duration <= 0.0:
                failures.append(name)
        except Exception as exc:
            print(f"  {name}: FAILED: {exc}", file=sys.stderr)
            failures.append(name)
    if failures:
        print("FAILED: " + ", ".join(sorted(set(failures))), file=sys.stderr)
        return 1
    print("music generation complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
