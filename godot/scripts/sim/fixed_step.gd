class_name FixedStep
extends RefCounted
## Fixed 60 Hz simulation clock. `advance()` returns how many sim ticks to run
## this frame (never more than MAX_STEPS); `alpha()` is the render interpolation
## factor between the previous and current sim state (prev_pos.lerp(pos, alpha)).

const STEP := 1.0 / 60.0
const MAX_STEPS := 2

var ticks := 0
var _acc := 0.0


func advance(frame_dt: float) -> int:
	_acc += maxf(frame_dt, 0.0)
	var n := 0
	while _acc >= STEP and n < MAX_STEPS:
		_acc -= STEP
		n += 1
	# Drop any backlog beyond one step so a long hitch never spirals.
	if _acc > STEP:
		_acc = STEP
	ticks += n
	return n


func alpha() -> float:
	return clampf(_acc / STEP, 0.0, 1.0)


func reset() -> void:
	_acc = 0.0
	ticks = 0
