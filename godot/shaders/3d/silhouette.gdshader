shader_type spatial;
// Hero occlusion silhouette: drawn only where the hero is hidden behind tall
// props (inverted depth test), as a material overlay on every hero surface.
render_mode unshaded, blend_mix, depth_test_inverted, depth_draw_never, cull_back, shadows_disabled;

uniform vec4 sil_color : source_color = vec4(0.55, 0.85, 1.0, 1.0);
uniform float intensity = 0.0;

void fragment() {
	float rim = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	ALBEDO = sil_color.rgb * (0.6 + 0.8 * rim);
	ALPHA = intensity * (0.35 + 0.5 * rim);
}
