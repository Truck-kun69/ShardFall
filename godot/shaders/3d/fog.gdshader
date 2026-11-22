shader_type spatial;
// Draped ground fog. No fragment discard: density fades to zero alpha instead.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

#include "res://shaders/3d/terrain_h.gdshaderinc"

uniform vec3 fog_color : source_color = vec3(0.6, 0.62, 0.64);
uniform float density : hint_range(0.0, 1.0) = 0.22;
uniform float lift = 7.0;
uniform float radius = 1100.0;

varying vec3 wpos;
varying vec2 local_xz;

void vertex() {
	local_xz = VERTEX.xz;
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y = terrain_h(w.xz) + lift - MODEL_MATRIX[3].y;
	wpos = vec3(w.x, VERTEX.y, w.z);
}

void fragment() {
	vec2 p = wpos.xz * 0.004;
	float t = TIME * 0.05;
	float n = 0.5 + 0.25 * sin(p.x * 3.1 + t * 2.0) * cos(p.y * 2.7 - t)
		+ 0.25 * sin((p.x - p.y) * 5.3 + t * 3.0);
	float edge = 1.0 - smoothstep(radius * 0.25, radius * 0.5, length(local_xz));
	ALBEDO = fog_color;
	ALPHA = clamp(density * n * edge, 0.0, 1.0);
}
