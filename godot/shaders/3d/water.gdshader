shader_type spatial;
render_mode cull_back, blend_mix, depth_draw_opaque, specular_schlick_ggx;

uniform vec3 liquid_color : source_color = vec3(0.16, 0.30, 0.36);
uniform float emissive = 0.0;
uniform float opacity = 0.82;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float t = TIME;
	vec2 p = wpos.xz;
	float w1 = sin(p.x * 0.031 + t * 1.1) * cos(p.y * 0.027 - t * 0.9);
	float w2 = sin((p.x + p.y) * 0.053 - t * 1.7);
	vec3 n = normalize(vec3(w1 * 0.25, 1.0, w2 * 0.25));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float glint = 0.5 + 0.5 * w1 * w2;
	ALBEDO = liquid_color * (0.85 + 0.15 * glint);
	ROUGHNESS = mix(0.08, 0.7, emissive);
	METALLIC = 0.0;
	EMISSION = liquid_color * emissive * (1.2 + 0.6 * glint);
	ALPHA = mix(opacity, 1.0, emissive);
}
