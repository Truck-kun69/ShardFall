class_name SpatialGrid
extends RefCounted
## Uniform hashed grid over pre-allocated linked lists (no per-frame allocation).
## Used by the swarm for separation and by weapons for area queries.

const CELL := 48.0
const BUCKETS := 4096

var head := PackedInt32Array()
var next := PackedInt32Array()
var _seen := PackedInt32Array()


func _init(cap: int) -> void:
	head.resize(BUCKETS)
	next.resize(cap)
	_seen.resize(64)
	clear()


func clear() -> void:
	head.fill(-1)


static func bucket(cx: int, cy: int) -> int:
	return ((cx * 73856093) ^ (cy * 19349663)) & (BUCKETS - 1)


func insert(i: int, x: float, y: float) -> void:
	var b := bucket(floori(x / CELL), floori(y / CELL))
	next[i] = head[b]
	head[b] = i


## Writes candidate indices into `out` (pre-sized by caller) and returns the count.
## Candidates are a superset; callers do the exact distance test.
func query(x: float, y: float, r: float, out: PackedInt32Array) -> int:
	var n := 0
	var cap := out.size()
	var x0 := floori((x - r) / CELL)
	var x1 := floori((x + r) / CELL)
	var y0 := floori((y - r) / CELL)
	var y1 := floori((y + r) / CELL)
	var seen_n := 0
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var b := bucket(cx, cy)
			var dup := false
			for s in seen_n:
				if _seen[s] == b:
					dup = true
					break
			if dup:
				continue
			if seen_n < _seen.size():
				_seen[seen_n] = b
				seen_n += 1
			var i := head[b]
			while i != -1:
				if n >= cap:
					return n
				out[n] = i
				n += 1
				i = next[i]
	return n
