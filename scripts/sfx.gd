class_name Sfx
extends Node

## Every sound in Sandwar is synthesised into 16-bit PCM at startup, so the game
## ships without audio assets and stays fully offline.

const RATE := 22050
const VOICES := 12
const UI_VOICES := 3

## Minimum gap in seconds between two instances of the same effect.
const MIN_GAP := {
	"shot": 0.05,
	"trike": 0.07,
	"cannon": 0.08,
	"explosion": 0.05,
	"big_explosion": 0.12,
	"build": 0.15,
	"deploy": 0.18,
	"harvest": 0.6,
	"coin": 0.4,
	"tap": 0.05,
	"alarm": 2.0,
	"frigate_rumble": 0.9,
	"ornithopter": 0.5,
	"missile_launch": 0.5,
}

var streams: Dictionary = {}
var voices: Array = []
var ui_voices: Array = []
var voice_i := 0
var ui_i := 0
var last_ms: Dictionary = {}
var ambience: AudioStreamPlayer
var rng := RandomNumberGenerator.new()

func _exit_tree() -> void:
	# Stop the looping wind bed and pooled voices before the scene tree goes
	# away; otherwise the audio server can report an orphaned playback at quit.
	if ambience != null:
		ambience.stop()
		ambience.stream = null
	for p in voices:
		p.stop()
		p.stream = null
	for p in ui_voices:
		p.stop()
		p.stream = null
	streams.clear()

func _ready() -> void:
	rng.randomize()
	for i in VOICES:
		var p := AudioStreamPlayer2D.new()
		p.max_distance = 900.0
		p.attenuation = 1.8
		add_child(p)
		voices.append(p)
	for i in UI_VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		ui_voices.append(p)
	_build_streams()
	ambience = AudioStreamPlayer.new()
	ambience.stream = streams["wind"]
	ambience.volume_db = -15.0
	add_child(ambience)
	ambience.play()

# --------------------------------------------------------------------- playing

## Positional effect: quieter with distance from the camera, panned by position.
func play_at(id: String, pos: Vector2, db := 0.0, pitch := 1.0) -> void:
	if not streams.has(id) or _throttled(id):
		return
	var p: AudioStreamPlayer2D = voices[voice_i]
	voice_i = (voice_i + 1) % voices.size()
	p.global_position = pos
	p.stream = streams[id]
	p.volume_db = db
	p.pitch_scale = pitch * rng.randf_range(0.94, 1.06)
	p.play()

## Non-positional effect for panel taps and alerts.
func ui(id: String, db := -8.0, pitch := 1.0) -> void:
	if not streams.has(id) or _throttled(id):
		return
	var p: AudioStreamPlayer = ui_voices[ui_i]
	ui_i = (ui_i + 1) % ui_voices.size()
	p.stream = streams[id]
	p.volume_db = db
	p.pitch_scale = pitch * rng.randf_range(0.97, 1.03)
	p.play()

func _throttled(id: String) -> bool:
	var now := Time.get_ticks_msec()
	var gap := int(float(MIN_GAP.get(id, 0.0)) * 1000.0)
	var last := int(last_ms.get(id, -100000))
	if now - last < gap:
		return true
	last_ms[id] = now
	return false

# ------------------------------------------------------------------ synthesis

func _build_streams() -> void:
	streams["shot"] = _wav(_gen_shot(0.13, 320.0, 34.0))
	streams["trike"] = _wav(_gen_burst())
	streams["cannon"] = _wav(_gen_cannon())
	streams["explosion"] = _wav(_gen_explosion(0.62))
	streams["big_explosion"] = _wav(_gen_explosion(1.45))
	streams["build"] = _wav(_gen_clank())
	streams["deploy"] = _wav(_gen_deploy())
	streams["harvest"] = _wav(_gen_harvest())
	streams["coin"] = _wav(_gen_coin())
	streams["tap"] = _wav(_gen_tap())
	streams["alarm"] = _wav(_gen_alarm())
	streams["frigate_rumble"] = _wav(_gen_frigate_rumble())
	streams["ornithopter"] = _wav(_gen_ornithopter())
	streams["missile_launch"] = _wav(_gen_missile_launch())
	streams["wind"] = _wav(_gen_wind(), true)

func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * float(RATE)))
	return b

## Normalise the buffer to a target peak and pack it as a mono 16-bit WAV.
func _wav(buf: PackedFloat32Array, looped := false, peak_target := 0.92) -> AudioStreamWAV:
	var peak := 0.0001
	for v in buf:
		peak = maxf(peak, absf(v))
	var gain := peak_target / peak
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(buf[i] * gain, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	if looped:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = buf.size()
	return wav

## Rifle crack: filtered noise over a fast downward pitch sweep.
func _gen_shot(seconds: float, body: float, drop: float, peak := 0.62) -> PackedFloat32Array:
	var b := _buf(seconds)
	var lp := 0.0
	var phase := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		lp += 0.45 * (rng.randf_range(-1.0, 1.0) - lp)
		phase += TAU * (body * exp(-t * drop) + 55.0) / float(RATE)
		b[i] = (lp * 0.9 + sin(phase) * 0.55) * exp(-t * 36.0)
	return _scale(b, peak)

## Trike machine gun: three short cracks in a row.
func _gen_burst() -> PackedFloat32Array:
	var b := _buf(0.22)
	var lp := 0.0
	var phase := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		var local := fmod(t, 0.062)
		var n := rng.randf_range(-1.0, 1.0)
		lp += 0.5 * (n - lp)
		phase += TAU * (210.0 * exp(-local * 40.0) + 60.0) / float(RATE)
		var gate := 1.0 if t < 0.19 else 0.0
		b[i] = (lp * 0.95 + sin(phase) * 0.5) * exp(-local * 55.0) * gate
	return _scale(b, 0.55)

## Turret gun: a heavier, lower thump.
func _gen_cannon() -> PackedFloat32Array:
	var b := _buf(0.34)
	var lp := 0.0
	var phase := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		lp += 0.16 * (rng.randf_range(-1.0, 1.0) - lp)
		phase += TAU * (110.0 * exp(-t * 5.0) + 42.0) / float(RATE)
		b[i] = (lp * 1.3 + sin(phase) * 0.8) * exp(-t * 13.0)
	return _scale(b, 0.9)

## Explosion: low-passed noise, sub-bass drop and an initial crack.
func _gen_explosion(seconds: float) -> PackedFloat32Array:
	var b := _buf(seconds)
	var lp := 0.0
	var lp2 := 0.0
	var phase := 0.0
	var decay := 3.0 if seconds > 1.0 else 5.0
	for i in b.size():
		var t := float(i) / float(RATE)
		var n := rng.randf_range(-1.0, 1.0)
		lp += 0.10 * (n - lp)
		lp2 += 0.05 * (lp - lp2)
		phase += TAU * (72.0 * exp(-t * 3.0) + 28.0) / float(RATE)
		var crack := n * exp(-t * 55.0) * 0.55
		b[i] = (lp2 * 2.6 + sin(phase) * 0.8) * exp(-t * decay) + crack
	return _scale(b, 0.95)

## Structure work: three metallic hammer hits.
func _gen_clank() -> PackedFloat32Array:
	var b := _buf(0.44)
	var lp := 0.0
	var hits := [0.0, 0.09, 0.2]
	for i in b.size():
		var t := float(i) / float(RATE)
		lp += 0.55 * (rng.randf_range(-1.0, 1.0) - lp)
		var v := 0.0
		for h in hits:
			var d: float = t - float(h)
			if d >= 0.0:
				v += exp(-d * 46.0) * (lp * 0.8 + sin(TAU * 540.0 * d) * 0.45)
				v += exp(-d * 10.0) * sin(TAU * 188.0 * d) * 0.3
		b[i] = v
	return _scale(b, 0.8)

## Structure deployed: servo sweep ending in a heavy thud.
func _gen_deploy() -> PackedFloat32Array:
	var b := _buf(0.8)
	var lp := 0.0
	var phase := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		lp += 0.24 * (rng.randf_range(-1.0, 1.0) - lp)
		phase += TAU * (120.0 + 300.0 * t) / float(RATE)
		var env := smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.42, 0.58, t))
		var v := (sin(phase) * 0.55 + lp * 0.35) * env
		if t > 0.55:
			var d := t - 0.55
			v += exp(-d * 22.0) * sin(TAU * 76.0 * d) * 0.9
		b[i] = v
	return _scale(b, 0.9)

## Harvester grinding spice out of the sand.
func _gen_harvest() -> PackedFloat32Array:
	var b := _buf(0.34)
	var lp := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		lp += 0.30 * (rng.randf_range(-1.0, 1.0) - lp)
		var grind := 0.55 + 0.45 * sin(TAU * 21.0 * t)
		b[i] = lp * grind * sin(PI * clampf(t / 0.34, 0.0, 1.0))
	return _scale(b, 0.7)

## Spice delivered: two-note credit chime.
func _gen_coin() -> PackedFloat32Array:
	var b := _buf(0.3)
	for i in b.size():
		var t := float(i) / float(RATE)
		var v := 0.0
		if t < 0.1:
			v += sin(TAU * 1046.0 * t) * exp(-t * 26.0) * 0.6
		var d := t - 0.055
		if d >= 0.0:
			v += sin(TAU * 1568.0 * d) * exp(-d * 17.0) * 0.8
		b[i] = v
	return _scale(b, 0.7)

## Panel click.
func _gen_tap() -> PackedFloat32Array:
	var b := _buf(0.05)
	for i in b.size():
		var t := float(i) / float(RATE)
		var n := rng.randf_range(-1.0, 1.0)
		b[i] = n * exp(-t * 150.0) * 0.6 + sin(TAU * 1150.0 * t) * exp(-t * 95.0) * 0.5
	return _scale(b, 0.55)

## Incoming wave: two-tone horn with a slow warble.
func _gen_alarm() -> PackedFloat32Array:
	var b := _buf(1.6)
	var p1 := 0.0
	var p2 := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		var wob := 1.0 + 0.018 * sin(TAU * 5.5 * t)
		p1 += TAU * 150.0 * wob / float(RATE)
		p2 += TAU * 226.0 * wob / float(RATE)
		var env := smoothstep(0.0, 0.07, t) * (1.0 - smoothstep(1.15, 1.6, t))
		var v := sin(p1) + 0.3 * sin(p1 * 2.0) + 0.15 * sin(p1 * 3.0) + 0.5 * sin(p2)
		b[i] = v * env * 0.5
	return _scale(b, 0.85)

## CHOAM frigate engine: low turbine rumble with a slow mechanical beat. It is
## played during descent, touchdown and climb-out so the dropship has weight.
func _gen_frigate_rumble() -> PackedFloat32Array:
	var b := _buf(2.4)
	var lp := 0.0
	var lp2 := 0.0
	var phase := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		var n := rng.randf_range(-1.0, 1.0)
		lp += 0.025 * (n - lp)
		lp2 += 0.008 * (lp - lp2)
		var beat := 0.68 + 0.32 * sin(TAU * 13.0 * t + sin(TAU * 2.2 * t) * 0.8)
		phase += TAU * (38.0 + 9.0 * sin(TAU * 0.7 * t)) / float(RATE)
		var env := smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(2.1, 2.4, t))
		b[i] = (lp2 * 4.0 + lp * 0.65 * beat + sin(phase) * 0.16) * env
	return _scale(b, 0.92)

## Ornithopter turbine whine with a fast blade flutter.
func _gen_ornithopter() -> PackedFloat32Array:
	var b := _buf(0.75)
	var phase := 0.0
	var phase2 := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		phase += TAU * (420.0 + 130.0 * t) / float(RATE)
		phase2 += TAU * (760.0 + 90.0 * t) / float(RATE)
		var flutter := 0.55 + 0.45 * sin(TAU * 23.0 * t)
		var env := smoothstep(0.0, 0.05, t) * (1.0 - smoothstep(0.58, 0.75, t))
		b[i] = (sin(phase) * 0.42 + sin(phase2) * 0.16 + rng.randf_range(-1.0, 1.0) * 0.10) * flutter * env
	return _scale(b, 0.74)

## Death Hand ignition: a deep pressure thump followed by a rising rocket roar.
func _gen_missile_launch() -> PackedFloat32Array:
	var b := _buf(1.5)
	var lp := 0.0
	var phase := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		var n := rng.randf_range(-1.0, 1.0)
		lp += 0.06 * (n - lp)
		phase += TAU * (55.0 + 180.0 * t) / float(RATE)
		var env := smoothstep(0.0, 0.05, t) * (1.0 - smoothstep(1.15, 1.5, t))
		var thump := exp(-t * 9.0) * sin(TAU * 46.0 * t) * 1.1
		b[i] = (lp * 1.7 + sin(phase) * 0.55 + thump) * env
	return _scale(b, 0.95)

## Desert wind bed. Built longer than the loop, then folded so the seam is silent.
func _gen_wind() -> PackedFloat32Array:
	var seconds := 6.0
	var fade := 0.7
	var b := _buf(seconds + fade)
	var lp := 0.0
	var lp2 := 0.0
	for i in b.size():
		var t := float(i) / float(RATE)
		var n := rng.randf_range(-1.0, 1.0)
		lp += 0.035 * (n - lp)
		lp2 += 0.018 * (lp - lp2)
		var swell := 0.6 + 0.25 * sin(TAU * 0.11 * t) + 0.15 * sin(TAU * 0.27 * t + 1.3)
		b[i] = lp2 * swell
	var out := PackedFloat32Array()
	out.resize(int(seconds * float(RATE)))
	for i in out.size():
		out[i] = b[i]
	var nf := int(fade * float(RATE))
	for i in nf:
		var k := float(i) / float(nf)
		out[i] = out[i] * k + b[out.size() + i] * (1.0 - k)
	return out

func _scale(buf: PackedFloat32Array, peak_target: float) -> PackedFloat32Array:
	var peak := 0.0001
	for v in buf:
		peak = maxf(peak, absf(v))
	var gain := peak_target / peak
	for i in buf.size():
		buf[i] = buf[i] * gain
	return buf
