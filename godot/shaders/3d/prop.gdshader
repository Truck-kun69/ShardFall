shader_type spatial;
// Procedural / vertex-coloured props. Never used on PBR asset meshes.
// No fragment discard (grass and bushes are solid geometry).
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.96, 0.95, 0.93);
uniform float sway = 0.0;
uniform float roughness = 0.86;

void vertex() {
	// INSTANCE_CUSTOM.r: per-instance colour jitter, .g: sway phase.
	float h = max(VERTEX.y, 0.0);
	vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float ph = INSTANCE_CUSTOM.g * 6.2831 + TIME * 1.3 + wp.x * 0.01;
	VERTEX.x += sin(ph) * sway * h * h * 0.0004;
	VERTEX.z += cos(ph * 0.8) * sway * h * h * 0.0003;
	COLOR.rgb *= 0.9 + 0.2 * INSTANCE_CUSTOM.r;
}

void fragment() {
	ALBEDO = COLOR.rgb * tint;
	ROUGHNESS = roughness;
	SPECULAR = 0.3;
}
