shader_type spatial;
// Ground decal (8x8 subdivided plane) draped on the terrain: marks, telegraphs,
// rings. Shape and colour come from per-instance uniforms so one material is shared.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

#include "res://shaders/3d/terrain_h.gdshaderinc"

instance uniform vec4 d_color = vec4(1.0, 0.5, 0.2, 0.6);
// x: shape (0 disc, 1 ring, 2 cone, 3 lane), y: progress 0..1, z: arc (radians), w: ring width
instance uniform vec4 d_shape = vec4(0.0, 1.0, 6.2831, 0.12);
uniform float lift = 1.2;

varying vec2 local_uv;

void vertex() {
	local_uv = UV * 2.0 - 1.0;
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Decal instances are yaw+uniform-xz-scale only, so world Y maps 1:1 to local Y.
	VERTEX.y = terrain_h(w.xz) + lift - MODEL_MATRIX[3].y;
}

void fragment() {
	float r = length(local_uv);
	float shape = d_shape.x;
	float prog = d_shape.y;
	float a = 0.0;
	float edge = 1.0 - smoothstep(0.94, 1.0, r);
	if (shape < 0.5) {
		a = edge * (0.55 + 0.45 * smoothstep(0.6, 1.0, r));
	} else if (shape < 1.5) {
		float wdt = d_shape.w;
		a = smoothstep(1.0 - wdt, 1.0 - wdt * 0.5, r) * edge;
	} else if (shape < 2.5) {
		float ang = abs(atan(local_uv.y, local_uv.x));
		float inside = 1.0 - smoothstep(d_shape.z * 0.5 - 0.04, d_shape.z * 0.5, ang);
		float fill = step(r, prog);
		a = inside * edge * (0.25 + 0.6 * fill + 0.4 * smoothstep(0.9, 1.0, r));
	} else {
		float lane = 1.0 - smoothstep(0.18, 0.24, abs(local_uv.y));
		float fwd = step(0.0, local_uv.x) * step(local_uv.x, prog);
		a = lane * (0.25 + 0.6 * fwd);
	}
	if (shape < 1.5 && prog < 1.0) {
		// Telegraph fill grows from the centre.
		a *= 0.35 + 0.65 * step(r, prog);
	}
	ALBEDO = d_color.rgb;
	ALPHA = clamp(a * d_color.a, 0.0, 1.0);
}
