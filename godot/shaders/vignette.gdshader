shader_type canvas_item;
// Screen vignette. Alpha is clamped to 0.35 (gloom floor).
uniform float strength : hint_range(0.0, 0.35) = 0.28;
uniform vec3 color : source_color = vec3(0.02, 0.02, 0.04);
uniform float hurt = 0.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float v = smoothstep(0.55, 1.45, length(p));
	float a = min(v * strength + hurt * v * 0.2, 0.35);
	COLOR = vec4(mix(color, vec3(0.6, 0.05, 0.05), hurt), a);
}
