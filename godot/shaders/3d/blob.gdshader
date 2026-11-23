shader_type spatial;
// Soft contact shadow blob under heroes, foes and bosses.
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform float strength = 0.55;

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float a = (1.0 - smoothstep(0.35, 1.0, r)) * strength * COLOR.a;
	ALBEDO = vec3(0.02, 0.02, 0.03);
	ALPHA = a;
}
