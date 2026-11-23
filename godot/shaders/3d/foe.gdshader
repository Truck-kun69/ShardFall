shader_type spatial;
// Swarm foes (MultiMesh). Supports SVA3 vertex animation (.vat) with the
// vertex column in UV2.x when the mesh is textured, plus albedo/normal/ORM PBR.
// INSTANCE_CUSTOM: r = anim phase, g = hit flash, b = status code, a = clip+progress
//   clip: 0 walk, 1 attack, 2 hit, 3 death, 4 spawn (integer part), progress = fract.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform bool has_albedo = false;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform bool has_normal = false;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform bool has_orm = false;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap;
uniform bool has_vat = false;
uniform sampler2D vat_tex : filter_nearest, repeat_disable;
uniform vec4 vat_walk = vec4(0.0, 1.0, 30.0, 0.0);    // start row, frames, fps, total rows
uniform vec4 vat_attack = vec4(0.0, 1.0, 30.0, 0.0);
uniform vec4 vat_hit = vec4(0.0, 1.0, 30.0, 0.0);
uniform vec4 vat_death = vec4(0.0, 1.0, 30.0, 0.0);
uniform vec4 vat_spawn = vec4(0.0, 1.0, 30.0, 0.0);
uniform float vat_rows = 1.0;
uniform vec3 tint_color : source_color = vec3(0.5);
uniform float tint_amount : hint_range(0.0, 0.1) = 0.1;
uniform float height = 28.0;
uniform float gait = 1.0;

varying float v_flash;
varying float v_status;

vec3 vat_offset(float col, vec4 clip, float prog) {
	float frame = floor(prog * max(clip.y - 1.0, 0.0) + 0.5);
	float row = (clip.x + frame + 0.5) / max(vat_rows, 1.0);
	return texture(vat_tex, vec2(col, row)).xyz;
}

void vertex() {
	float clip = floor(INSTANCE_CUSTOM.a);
	float prog = fract(INSTANCE_CUSTOM.a);
	float ph = INSTANCE_CUSTOM.r * 6.2831;
	v_flash = INSTANCE_CUSTOM.g;
	v_status = INSTANCE_CUSTOM.b;
	if (has_vat) {
		float col = has_albedo ? UV2.x : UV.x;
		vec4 c = vat_walk;
		float p = fract(INSTANCE_CUSTOM.r);
		if (clip > 0.5 && clip < 1.5) { c = vat_attack; p = prog; }
		else if (clip > 1.5 && clip < 2.5) { c = vat_hit; p = prog; }
		else if (clip > 2.5 && clip < 3.5) { c = vat_death; p = prog; }
		else if (clip > 3.5) { c = vat_spawn; p = prog; }
		VERTEX += vat_offset(col, c, p);
	} else {
		float hn = clamp(VERTEX.y / height, 0.0, 1.0);
		float legs = 1.0 - smoothstep(0.0, 0.45, hn);
		// Gait: legs scissor along +X (forward), torso bobs and rolls.
		float side = sign(VERTEX.z + 0.001);
		VERTEX.x += sin(ph + side * 1.5708) * legs * 3.0 * gait;
		VERTEX.y += abs(sin(ph)) * 1.2 * gait * hn;
		VERTEX.z += sin(ph * 0.5) * 0.8 * hn;
		VERTEX.x += hn * 2.0 * gait;   // lean into the run
		if (clip > 0.5 && clip < 1.5) {
			VERTEX.x += sin(prog * 3.1416) * hn * 8.0;
		}
		if (clip > 2.5 && clip < 3.5) {
			// Death: tip over backwards and squash.
			float a = prog * 1.4;
			float y = VERTEX.y;
			VERTEX.y = y * cos(a) * (1.0 - prog * 0.4);
			VERTEX.x -= y * sin(a);
		}
		if (clip > 3.5) {
			VERTEX.y -= (1.0 - prog) * height * 0.8;
		}
	}
	float squash = v_flash * 1.5;
	VERTEX.xz *= 1.0 + squash * 0.15;
	VERTEX.y *= 1.0 - squash * 0.12;
}

void fragment() {
	vec3 base = has_albedo ? texture(albedo_tex, UV).rgb : COLOR.rgb;
	float rough = 0.78;
	float metal = 0.0;
	if (has_orm) {
		vec3 orm = texture(orm_tex, UV).rgb;
		base *= mix(0.65, 1.0, orm.r);
		rough = orm.g;
		metal = orm.b;
	}
	base = mix(base, tint_color, tint_amount);
	ALBEDO = base;
	ROUGHNESS = rough;
	METALLIC = metal;
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	vec3 status_glow = vec3(0.0);
	if (v_status > 0.5 && v_status < 1.5) status_glow = vec3(1.0, 0.4, 0.1);
	else if (v_status > 1.5 && v_status < 2.5) status_glow = vec3(0.4, 0.8, 1.0);
	else if (v_status > 2.5 && v_status < 3.5) status_glow = vec3(1.0, 0.9, 0.3);
	else if (v_status > 3.5 && v_status < 4.5) status_glow = vec3(0.7, 0.3, 1.0);
	else if (v_status > 4.5) status_glow = vec3(1.0, 0.75, 0.3);
	EMISSION = vec3(1.0, 0.92, 0.85) * v_flash * 6.0 + status_glow * 0.35;
}
