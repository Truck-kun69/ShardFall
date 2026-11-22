shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/3d/terrain_h.gdshaderinc"

uniform sampler2D tex_a : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_b : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_rock : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_a_n : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D tex_rock_n : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float tex_scale = 0.0085;
uniform float tint : hint_range(0.0, 1.0) = 0.18;
uniform vec3 pal_a : source_color = vec3(0.42, 0.45, 0.30);
uniform vec3 pal_b : source_color = vec3(0.36, 0.31, 0.24);
uniform float grass_w : hint_range(0.0, 1.0) = 0.6;
uniform vec3 patch_color : source_color = vec3(0.2, 0.18, 0.16);
uniform float patch_gloss = 0.0;
uniform float has_liquid = 1.0;
uniform float liquid_level = -20.0;

varying vec3 wpos;
varying float slope_v;

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = terrain_h(w.xz);
	VERTEX.y = h - MODEL_MATRIX[3].y;
	vec3 n = terrain_normal(w.xz);
	NORMAL = n;
	TANGENT = normalize(cross(vec3(0.0, 0.0, 1.0), n));
	BINORMAL = normalize(cross(n, TANGENT));
	wpos = vec3(w.x, h, w.z);
	slope_v = 1.0 - n.y;
}

float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

void fragment() {
	vec2 uv = wpos.xz * tex_scale;
	vec3 a = texture(tex_a, uv).rgb;
	vec3 b = texture(tex_b, uv * 0.73 + vec2(0.31, 0.17)).rgb;
	vec3 r = texture(tex_rock, uv * 1.21).rgb;
	float macro = 0.5 + 0.5 * sin(wpos.x * 0.0021 + t_seeds.z) * cos(wpos.z * 0.0024 + t_seeds.x);
	float gmask = smoothstep(0.35, 0.65, macro * 0.6 + grass_w * 0.7 - 0.15);
	float rmask = smoothstep(0.10, 0.30, slope_v);
	vec3 base = mix(mix(b, a, gmask), r, rmask);
	vec3 pal = mix(pal_b, pal_a, gmask);
	// Gentle palette grading: the texture keeps its detail, the act sets the hue.
	vec3 col = mix(base, pal * (0.55 + luma(base)), tint);
	float rough = mix(0.92, 0.78, rmask);
	if (has_liquid > 0.5) {
		float wet = smoothstep(liquid_level + 6.0, liquid_level, wpos.y);
		col *= mix(1.0, 0.62, wet);
		rough = mix(rough, 0.35, wet);
	}
	float pd = dot(wpos.xz, wpos.xz);
	float pm = smoothstep(1.05, 1.12, terrain_patch(wpos.xz)) * step(260.0 * 260.0, pd);
	float stipple = 0.75 + 0.25 * sin(wpos.x * 0.9) * sin(wpos.z * 0.9);
	col = mix(col, patch_color * stipple, pm * 0.75);
	rough = mix(rough, mix(0.9, 0.15, patch_gloss), pm);
	ALBEDO = col;
	ROUGHNESS = rough;
	NORMAL_MAP = mix(texture(tex_a_n, uv).rgb, texture(tex_rock_n, uv * 1.21).rgb, rmask);
	NORMAL_MAP_DEPTH = 0.8;
}
