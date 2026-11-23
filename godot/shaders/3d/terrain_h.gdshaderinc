// Shared analytic terrain height. MUST stay identical to Terrain.height()
// in scripts/sim/terrain.gd: ground, decals, fog and FX all drape on it.
uniform float t_amp = 44.0;
uniform vec4 t_seeds = vec4(0.0);

float terrain_h(vec2 p) {
	float hb = t_amp * (0.55 * sin(p.x * 0.0041 + t_seeds.x) * cos(p.y * 0.0037 + t_seeds.y)
		+ 0.30 * sin((p.x + p.y) * 0.0063 + t_seeds.z)
		+ 0.15 * sin(p.x * 0.0117 - p.y * 0.0093 + t_seeds.w));
	float w = exp(-dot(p, p) / (420.0 * 420.0));
	return hb + w * max(10.0 - hb, 0.0);
}

float terrain_patch(vec2 p) {
	return sin(p.x * 0.011 + t_seeds.y * 2.0) * sin(p.y * 0.013 + t_seeds.x * 2.0)
		+ 0.5 * sin((p.x - p.y) * 0.007 + t_seeds.w);
}

vec3 terrain_normal(vec2 p) {
	float e = 3.0;
	float hx = terrain_h(p + vec2(e, 0.0)) - terrain_h(p - vec2(e, 0.0));
	float hz = terrain_h(p + vec2(0.0, e)) - terrain_h(p - vec2(0.0, e));
	return normalize(vec3(-hx, 2.0 * e, -hz));
}
