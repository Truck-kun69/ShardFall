shader_type spatial;
// Projectiles, blades, gems, sparks: unshaded HDR colour (instance colour)
// so bright elements bloom above the glow threshold.
render_mode unshaded, blend_mix, cull_back, shadows_disabled;

uniform float energy = 2.2;

void fragment() {
	ALBEDO = COLOR.rgb * energy;
	ALPHA = COLOR.a;
}
