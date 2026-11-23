shader_type spatial;
// Boss hit-flash overlay. Compiled once and cached statically by BossRig.
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

uniform float flash = 0.0;
uniform vec3 flash_color : source_color = vec3(1.0, 0.9, 0.8);

void fragment() {
	ALBEDO = flash_color * flash;
	ALPHA = flash;
}
